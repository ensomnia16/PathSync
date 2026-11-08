"""Read-only accounting for one local tree and its OneDrive mirror."""
import argparse
import json
import os
from pathlib import Path
import stat
import sys
import sqlite3
import unicodedata
import graph_index

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
            return {unicodedata.normalize('NFC', entry.name) for entry in entries}
    except OSError:
        totals['errors'] += 1
        return None


def analyze(local, cloud, scope='', verify=False, cloud_index=None):
    local, cloud = Path(local).resolve(strict=True), Path(cloud).resolve(strict=True)
    if local == cloud or local in cloud.parents or cloud in local.parents:
        raise ValueError('Analysis roots must be separate folders.')
    if scope:
        scope = validate_relative(scope)
    snapshot, cloud_warning = None, None
    if cloud_index:
        try:
            snapshot = graph_index.cached_snapshot(cloud_index, local, cloud)
        except (OSError, ValueError, KeyError, sqlite3.Error) as error:
            cloud_warning = str(error)
    remote_sizes, remote_directories = {}, set()
    prefix = scope + '/' if scope else ''
    if snapshot:
        for path, item in snapshot['entries'].items():
            path = unicodedata.normalize('NFC', path)
            if not path.startswith(prefix):
                continue
            tail = path[len(prefix):]
            if not tail:
                continue
            name = prefix + tail.split('/')[0]
            remote_sizes[name] = remote_sizes.get(name, 0) + item['size']
            if '/' in tail:
                remote_directories.add(name)
    roots = [safe_target(root, scope) if scope else root for root in (local, cloud)]
    root_info = [inspect(path) for path in roots]
    if not any(map(directory, root_info)) and not remote_sizes:
        raise ValueError('The selected folder is unavailable.')
    totals = dict.fromkeys(FIELDS, 0)
    devices = (local.stat().st_dev, cloud.stat().st_dev)
    if any(info is not None and not directory(info) for info in root_info):
        raise ValueError('The selected path has different types on the two sides.')
    left_names = children(roots[0], root_info[0], devices[0], totals)
    right_names = children(roots[1], root_info[1], devices[1], totals)
    names = (left_names or set()) | (right_names or set()) | {name[len(prefix):] for name in remote_sizes}
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
        row['isDirectory'] |= relative in remote_directories
        row['hasCloud'] |= relative in remote_sizes
        row['usage'] = {field: row.pop(field) for field in FIELDS}
        row['usage']['cloudLogicalBytes'] = remote_sizes.get(relative, 0) if snapshot else None
        for field in FIELDS:
            totals[field] += row['usage'][field]
        rows.append(row)
    totals['cloudLogicalBytes'] = sum(remote_sizes.values()) if snapshot else None
    return {'rows': sorted(rows, key=lambda row: (-row['usage']['localBytes'], row['path'])),
            'totals': totals, 'cloudIndexUpdatedAt': snapshot['updated'] if snapshot else None,
            'cloudIndexWarning': cloud_warning}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local')
    parser.add_argument('cloud')
    parser.add_argument('--scope', default='')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--cloud-index', type=Path)
    parser.add_argument('--refresh-cloud-index', action='store_true')
    parser.add_argument('--graph-auth-helper', type=Path)
    parser.add_argument('--onedrive-root', type=Path)
    args = parser.parse_args()
    try:
        from sync_merge import enable_cloud_materialization
        enable_cloud_materialization(False)
        warning = None
        if args.refresh_cloud_index:
            client = index = None
            try:
                if not (args.cloud_index and args.graph_auth_helper and args.onedrive_root):
                    raise ValueError('云端大小查询缺少 OneDrive 配置。')
                local, cloud = Path(args.local).resolve(strict=True), Path(args.cloud).resolve(strict=True)
                relative = cloud.relative_to(args.onedrive_root.resolve(strict=True)).as_posix()
                auth = graph_index.credentials(args.graph_auth_helper)
                client = graph_index.GraphClient(auth['access_token'])
                index = graph_index.GraphIndex(args.cloud_index, local, cloud, auth['drive_id'], relative, client.get)
                index.refresh()
            except (OSError, ValueError, KeyError, sqlite3.Error) as error:
                warning = '云端刷新未完成：' + str(error)
            finally:
                if index: index.close()
                if client: client.close()
        result = analyze(args.local, args.cloud, args.scope, args.verify, args.cloud_index)
        if warning:
            result['cloudIndexWarning'] = warning
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    json.dump(result, sys.stdout)


if __name__ == '__main__':
    main()
