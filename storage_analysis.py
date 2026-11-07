"""Read-only accounting for one local tree and its OneDrive mirror."""
import argparse
import json
import os
from pathlib import Path
import stat
import sys

from cloud_only import _record, safe_target, secure_digest, validate_relative

DATALESS = getattr(stat, 'SF_DATALESS', 0x40000000)
FIELDS = ('localBytes', 'cloudBytes', 'verifiedBytes', 'differentBytes',
          'unverifiedBytes', 'errors')


def allocated(info, seen):
    if info is None or not stat.S_ISREG(info.st_mode):
        return 0
    identity = (info.st_dev, info.st_ino)
    if info.st_nlink > 1:
        if identity in seen:
            return 0
        seen.add(identity)
    return info.st_blocks * 512


def inspect(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def directory(info):
    return info is not None and stat.S_ISDIR(info.st_mode)


def dataless(info):
    return bool(getattr(info, 'st_flags', 0) & DATALESS)


def children(path, info, device, totals):
    if not directory(info):
        return set()
    if info.st_dev != device or dataless(info):
        totals['errors'] += 1
        return None
    try:
        with os.scandir(path) as entries:
            return {entry.name for entry in entries}
    except OSError:
        totals['errors'] += 1
        return None


def analyze(local, cloud, scope='', verify=False):
    local, cloud = Path(local).resolve(strict=True), Path(cloud).resolve(strict=True)
    if local == cloud or local in cloud.parents or cloud in local.parents:
        raise ValueError('Analysis roots must be separate folders.')
    if scope:
        scope = validate_relative(scope)
    roots = [safe_target(root, scope) if scope else root for root in (local, cloud)]
    root_info = [inspect(path) for path in roots]
    if not any(map(directory, root_info)):
        raise ValueError('The selected folder is unavailable.')
    totals = dict.fromkeys(FIELDS, 0)
    devices = (local.stat().st_dev, cloud.stat().st_dev)
    if any(info is not None and not directory(info) for info in root_info):
        raise ValueError('The selected path has different types on the two sides.')
    left_names = children(roots[0], root_info[0], devices[0], totals)
    right_names = children(roots[1], root_info[1], devices[1], totals)
    names = (left_names or set()) | (right_names or set())
    local_seen, cloud_seen = set(), set()
    rows = []
    for name in sorted(names):
        relative = f'{scope}/{name}' if scope else name
        row = dict.fromkeys(FIELDS, 0)
        row['path'] = relative
        try:
            validate_relative(relative)
            row['selectable'] = True
        except ValueError:
            row['selectable'] = False
        row.update(isDirectory=False, hasCloud=False)
        stack = [(relative, True, left_names is not None, right_names is not None)]
        while stack:
            path, top, inspect_left, inspect_right = stack.pop()
            left_path, right_path = local / path, cloud / path
            try:
                left = inspect(left_path) if inspect_left else None
                right = inspect(right_path) if inspect_right else None
            except OSError:
                row['errors'] += 1
                if top:
                    row['selectable'] = False
                continue
            if top:
                row['isDirectory'] = directory(left) or directory(right)
                row['hasCloud'] = right is not None and (
                    directory(right) or stat.S_ISREG(right.st_mode))
                row['selectable'] &= inspect_left and row['hasCloud'] and (
                    left is None or stat.S_IFMT(left.st_mode) == stat.S_IFMT(right.st_mode))
            left_bytes = allocated(left, local_seen)
            row['localBytes'] += left_bytes
            row['cloudBytes'] += allocated(right, cloud_seen)
            # Descend through the directory side of a type conflict only.
            left_children = children(left_path, left, devices[0], row) if inspect_left else None
            right_children = children(right_path, right, devices[1], row) if inspect_right else None
            stack.extend((f'{path}/{child}', False, left_children is not None and (left is None or directory(left)), right_children is not None
                          and (right is None or directory(right)))
                         for child in (left_children or set()) | (right_children or set()))
            if not left_bytes:
                continue
            if not inspect_right:
                row['unverifiedBytes'] += left_bytes
                continue
            if (right is None or not stat.S_ISREG(right.st_mode)
                    or right.st_size != left.st_size):
                row['differentBytes'] += left_bytes
                continue
            if not verify or dataless(left) or dataless(right):
                row['unverifiedBytes'] += left_bytes
                continue
            try:
                same = secure_digest(local, path, _record(left)) == secure_digest(cloud, path, _record(right))
            except (OSError, ValueError):
                row['unverifiedBytes'] += left_bytes
                row['errors'] += 1
            else:
                row['verifiedBytes' if same else 'differentBytes'] += left_bytes
        row['usage'] = {field: row.pop(field) for field in FIELDS}
        for field in FIELDS:
            totals[field] += row['usage'][field]
        rows.append(row)
    return {'rows': sorted(rows, key=lambda row: (-row['usage']['localBytes'], row['path'])),
            'totals': totals}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local')
    parser.add_argument('cloud')
    parser.add_argument('--scope', default='')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    try:
        result = analyze(args.local, args.cloud, args.scope, args.verify)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    json.dump(result, sys.stdout)


if __name__ == '__main__':
    main()
