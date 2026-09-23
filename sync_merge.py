#!/usr/bin/env python3
"""Conservative, non-deleting two-way folder merge.

The first run treats different same-path files as conflicts. Subsequent runs use
the last successful per-file signatures to identify which side changed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from sync_tree import ALWAYS_EXCLUDE_DIRS, LATEX_EXCLUDE_DIRS, excluded


def signature(path):
    try:
        stat = path.stat()
    except FileNotFoundError:
        return None
    if not path.is_file() or path.is_symlink():
        return None
    return [stat.st_size, stat.st_mtime_ns]


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.digest()


def same_content(local_file, cloud_file, local_sig, cloud_sig):
    equal = digest(local_file) == digest(cloud_file)
    if signature(local_file) != local_sig or signature(cloud_file) != cloud_sig:
        raise OSError('文件在读取过程中发生变化，已跳过本次比较')
    return equal


def scan(root, exclude_latex, errors):
    found = set()

    def walk_error(error):
        errors.append((str(error.filename), str(error)))

    for current, dirs, files in os.walk(root, onerror=walk_error):
        dirs[:] = [name for name in dirs
                   if name not in ALWAYS_EXCLUDE_DIRS
                   and not (exclude_latex and any(name.startswith(prefix) for prefix in LATEX_EXCLUDE_DIRS))
                   and not (Path(current) / name).is_symlink()]
        for name in files:
            if excluded(name, exclude_latex):
                continue
            path = Path(current) / name
            if not path.is_symlink():
                found.add(path.relative_to(root).as_posix())
    return found


def copy_atomic(source, destination, source_sig, destination_sig):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + '.researchsync-partial')
    try:
        if temporary.exists():
            temporary.unlink()
        shutil.copy2(source, temporary)
        if signature(source) != source_sig or signature(destination) != destination_sig:
            raise OSError('文件在复制过程中发生变化，已跳过本次复制')
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def load_state(path, local, cloud):
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('version') != 1 or data.get('local') != str(local) or data.get('cloud') != str(cloud):
        raise ValueError('同步路径已改变；请先检查旧的合并状态文件')
    return data.get('files', {})


def save_state(path, local, cloud, files):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {'version': 1, 'local': str(local), 'cloud': str(cloud), 'files': files}
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                     prefix=path.name + '.', delete=False) as target:
        json.dump(data, target, ensure_ascii=False, sort_keys=True)
        target.flush()
        os.fsync(target.fileno())
        temporary = Path(target.name)
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local', type=Path)
    parser.add_argument('cloud', type=Path)
    parser.add_argument('state', type=Path)
    parser.add_argument('--exclude-latex', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    local = args.local.resolve()
    cloud = args.cloud.resolve()
    state = load_state(args.state, local, cloud)
    next_state = dict(state)
    errors = []
    names = scan(local, args.exclude_latex, errors) | scan(cloud, args.exclude_latex, errors)
    counts = {'uploaded': 0, 'downloaded': 0, 'unchanged': 0, 'conflicts': 0, 'failed': 0}

    for name in sorted(names):
        local_file = local / name
        cloud_file = cloud / name
        try:
            local_sig = signature(local_file)
            cloud_sig = signature(cloud_file)
            if local_sig is None and cloud_sig is None:
                continue
            if local_sig is None or cloud_sig is None:
                upload = cloud_sig is None
                source = local_file if upload else cloud_file
                destination = cloud_file if upload else local_file
                if not args.dry_run:
                    copy_atomic(source, destination, local_sig if upload else cloud_sig,
                                cloud_sig if upload else local_sig)
                    next_state[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
                counts['uploaded' if upload else 'downloaded'] += 1
                continue

            previous = state.get(name)
            if previous and local_sig == previous['local'] and cloud_sig == previous['cloud']:
                if not args.dry_run:
                    next_state[name] = {'local': local_sig, 'cloud': cloud_sig}
                counts['unchanged'] += 1
                continue

            compared = None
            if local_sig == cloud_sig:
                compared = same_content(local_file, cloud_file, local_sig, cloud_sig)
            if compared is True:
                if not args.dry_run:
                    next_state[name] = {'local': local_sig, 'cloud': cloud_sig}
                counts['unchanged'] += 1
                continue

            local_changed = previous is None or local_sig != previous['local']
            cloud_changed = previous is None or cloud_sig != previous['cloud']
            if local_changed and not cloud_changed:
                direction = 'uploaded'
            elif cloud_changed and not local_changed:
                direction = 'downloaded'
            elif (compared if compared is not None else same_content(local_file, cloud_file, local_sig, cloud_sig)):
                if not args.dry_run:
                    next_state[name] = {'local': local_sig, 'cloud': cloud_sig}
                counts['unchanged'] += 1
                continue
            else:
                print(f'CONFLICT\t{name}\t两侧均已更改，保留两份原件')
                counts['conflicts'] += 1
                continue

            upload = direction == 'uploaded'
            if not args.dry_run:
                copy_atomic(local_file if upload else cloud_file,
                            cloud_file if upload else local_file,
                            local_sig if upload else cloud_sig,
                            cloud_sig if upload else local_sig)
                next_state[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
            counts[direction] += 1
        except (OSError, ValueError) as error:
            print(f'FAILED\t{name}\t{error}')
            counts['failed'] += 1

    for path, error in errors:
        print(f'FAILED\t{path}\t{error}')
        counts['failed'] += 1
    if not args.dry_run:
        save_state(args.state, local, cloud, next_state)
    print(' '.join(f'{key}={value}' for key, value in counts.items()))
    return 2 if counts['conflicts'] or counts['failed'] else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f'FAILED\t{error}', file=sys.stderr)
        sys.exit(2)
