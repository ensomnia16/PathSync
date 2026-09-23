#!/usr/bin/env python3
"""Non-deleting folder sync with explicit, recoverable conflict resolution."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

from sync_tree import ALWAYS_EXCLUDE_DIRS, LATEX_EXCLUDE_DIRS, excluded


def safe_path(root, name):
    relative = Path(name)
    if relative.is_absolute() or not relative.parts or '..' in relative.parts:
        raise ValueError(f'不安全的相对路径：{name}')
    path = root
    for part in relative.parts:
        path = path / part
        if path.is_symlink():
            raise OSError(f'路径包含符号链接，已跳过：{path}')
    return path


def signature(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise OSError(f'不是普通文件，已跳过：{path}')
    return [info.st_size, info.st_mtime_ns]


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def checked_digests(local_file, cloud_file, local_sig, cloud_sig):
    local_hash = digest(local_file)
    cloud_hash = digest(cloud_file)
    if signature(local_file) != local_sig or signature(cloud_file) != cloud_sig:
        raise OSError('文件在读取过程中发生变化，已跳过本次比较')
    return local_hash, cloud_hash


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
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()
        shutil.copy2(source, temporary)
        if signature(source) != source_sig or signature(destination) != destination_sig:
            raise OSError('文件在复制过程中发生变化，已跳过本次复制')
        os.replace(temporary, destination)
    finally:
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()


def load_state(path, local, cloud):
    if not path.exists():
        return {}, {}
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('version') != 1 or data.get('local') != str(local) or data.get('cloud') != str(cloud):
        raise ValueError('同步路径已改变；请先检查旧的合并状态文件')
    files = data.get('files', {})
    conflicts = data.get('conflicts', {})
    if (not isinstance(files, dict) or not isinstance(conflicts, dict)
            or any(not isinstance(value, dict) for value in files.values())
            or any(not isinstance(value, dict) for value in conflicts.values())):
        raise ValueError('合并状态文件格式无效')
    return files, conflicts


def save_state(path, local, cloud, files, conflicts):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {'version': 1, 'local': str(local), 'cloud': str(cloud),
            'files': files, 'conflicts': conflicts}
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                     prefix=path.name + '.', delete=False) as target:
        json.dump(data, target, ensure_ascii=False, sort_keys=True)
        target.flush()
        os.fsync(target.fileno())
        temporary = Path(target.name)
    os.replace(temporary, path)


def conflict_record(local_sig, cloud_sig, hashes, reason):
    return {'local': local_sig, 'cloud': cloud_sig,
            'localHash': hashes[0], 'cloudHash': hashes[1],
            'reason': reason, 'detectedAt': datetime.now(timezone.utc).isoformat()}


def sync_files(args, local, cloud, files, conflicts):
    next_files = dict(files)
    next_conflicts = dict(conflicts)
    errors = []
    names = scan(local, args.exclude_latex, errors) | scan(cloud, args.exclude_latex, errors)
    counts = {'uploaded': 0, 'downloaded': 0, 'unchanged': 0,
              'skipped': 0, 'conflicts': 0, 'failed': 0}

    for name in sorted(names):
        try:
            local_file = safe_path(local, name)
            cloud_file = safe_path(cloud, name)
            local_sig = signature(local_file)
            cloud_sig = signature(cloud_file)
            if local_sig is None and cloud_sig is None:
                continue
            if name in conflicts and (local_sig is None or cloud_sig is None):
                print(f'CONFLICT\t{name}\t待处理冲突的一侧文件已缺失')
                continue
            if local_sig is None or cloud_sig is None:
                upload = cloud_sig is None
                if args.direction != 'merge' and (args.direction == 'upload') != upload:
                    counts['skipped'] += 1
                    continue
                source = local_file if upload else cloud_file
                destination = cloud_file if upload else local_file
                if not args.dry_run:
                    copy_atomic(source, destination, local_sig if upload else cloud_sig, None)
                    next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
                    next_conflicts.pop(name, None)
                counts['uploaded' if upload else 'downloaded'] += 1
                continue

            previous = files.get(name)
            if (name not in conflicts and previous
                    and local_sig == previous.get('local')
                    and cloud_sig == previous.get('cloud')):
                counts['unchanged'] += 1
                continue

            local_changed = previous is None or local_sig != previous.get('local')
            cloud_changed = previous is None or cloud_sig != previous.get('cloud')
            pending = name in conflicts
            if pending or (local_changed and cloud_changed) or local_sig == cloud_sig:
                hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                if hashes[0] == hashes[1]:
                    if not args.dry_run:
                        next_files[name] = {'local': local_sig, 'cloud': cloud_sig}
                        next_conflicts.pop(name, None)
                    counts['unchanged'] += 1
                    continue
            else:
                hashes = None

            if pending or (args.direction == 'merge' and local_changed and cloud_changed) or (
                    args.direction == 'upload' and cloud_changed) or (
                    args.direction == 'download' and local_changed):
                if hashes is None:
                    hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                    if hashes[0] == hashes[1]:
                        if not args.dry_run:
                            next_files[name] = {'local': local_sig, 'cloud': cloud_sig}
                            next_conflicts.pop(name, None)
                        counts['unchanged'] += 1
                        continue
                reason = 'pending' if pending else ('initial' if previous is None else 'both_changed')
                if not args.dry_run:
                    next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes, reason)
                print(f'CONFLICT\t{name}\t两侧内容不同，等待选择版本')
                counts['conflicts'] += 1
                continue

            upload = args.direction == 'upload' or (args.direction == 'merge' and local_changed)
            if not args.dry_run:
                copy_atomic(local_file if upload else cloud_file,
                            cloud_file if upload else local_file,
                            local_sig if upload else cloud_sig,
                            cloud_sig if upload else local_sig)
                next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
                next_conflicts.pop(name, None)
            counts['uploaded' if upload else 'downloaded'] += 1
        except (OSError, ValueError) as error:
            print(f'FAILED\t{name}\t{error}')
            counts['failed'] += 1

    for path, error in errors:
        print(f'FAILED\t{path}\t{error}')
        counts['failed'] += 1
    if not args.dry_run:
        save_state(args.state, local, cloud, next_files, next_conflicts)
        counts['conflicts'] = len(next_conflicts)
    print(' '.join(f'{key}={value}' for key, value in counts.items()))
    return 2 if counts['conflicts'] or counts['failed'] else 0


def backup_original(source, destination, expected_hash):
    if destination.exists():
        if digest(destination) != expected_hash:
            raise OSError(f'备份文件与预期不同：{destination}')
        return
    copy_atomic(source, destination, signature(source), None)
    if digest(destination) != expected_hash:
        raise OSError(f'备份文件校验失败：{destination}')


def resolve_conflict(args, local, cloud, files, conflicts):
    name = args.resolve
    if name not in conflicts:
        raise ValueError(f'没有待处理冲突：{name}')
    record = conflicts[name]
    local_file = safe_path(local, name)
    cloud_file = safe_path(cloud, name)
    local_sig = signature(local_file)
    cloud_sig = signature(cloud_file)
    if local_sig != record['local'] or cloud_sig != record['cloud']:
        raise OSError('冲突文件在列出后又发生变化；请先重新同步，再选择版本')
    hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
    if hashes != (record['localHash'], record['cloudHash']):
        raise OSError('冲突文件内容在列出后发生变化；请先重新同步')

    key = hashlib.sha256(name.encode('utf-8')).hexdigest()[:16]
    version = hashes[0][:12] + '-' + hashes[1][:12]
    backup_dir = args.state.parent / (args.state.stem + '-conflict-backups') / key / version
    suffix = local_file.suffix
    local_backup = backup_dir / ('local' + suffix)
    cloud_backup = backup_dir / ('cloud' + suffix)
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_original(local_file, local_backup, hashes[0])
    backup_original(cloud_file, cloud_backup, hashes[1])

    if checked_digests(local_file, cloud_file, local_sig, cloud_sig) != hashes:
        raise OSError('备份期间文件发生变化；请重新同步')

    next_files = dict(files)
    next_conflicts = dict(conflicts)
    sidecar_name = None
    if args.choice == 'local':
        copy_atomic(local_backup, cloud_file, signature(local_backup), cloud_sig)
    elif args.choice == 'cloud':
        copy_atomic(cloud_backup, local_file, signature(cloud_backup), local_sig)
    else:
        relative = Path(name)
        sidecar_name = str(relative.with_name(
            relative.stem + ' (cloud conflict ' + hashes[1][:12] + ')' + relative.suffix))
        local_sidecar = safe_path(local, sidecar_name)
        cloud_sidecar = safe_path(cloud, sidecar_name)
        for target in (cloud_sidecar, local_sidecar):
            if signature(target) is not None and digest(target) != hashes[1]:
                raise OSError(f'冲突副本名称已被其他文件占用：{target}')
        for target in (cloud_sidecar, local_sidecar):
            existing = signature(target)
            if existing is None:
                copy_atomic(cloud_backup, target, signature(cloud_backup), None)
        if checked_digests(local_file, cloud_file, local_sig, cloud_sig) != hashes:
            raise OSError('创建冲突副本期间原文件发生变化；请重新同步')
        copy_atomic(local_backup, cloud_file, signature(local_backup), cloud_sig)
        next_files[sidecar_name] = {'local': signature(local_sidecar),
                                    'cloud': signature(cloud_sidecar)}

    next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
    next_conflicts.pop(name)
    save_state(args.state, local, cloud, next_files, next_conflicts)
    print(f'RESOLVED\t{name}\t{args.choice}\tbackup={backup_dir}'
          + (f'\tcopy={sidecar_name}' if sidecar_name else ''))
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local', type=Path)
    parser.add_argument('cloud', type=Path)
    parser.add_argument('state', type=Path)
    parser.add_argument('--direction', choices=('merge', 'upload', 'download'), default='merge')
    parser.add_argument('--exclude-latex', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--resolve', metavar='RELATIVE_PATH')
    parser.add_argument('--choice', choices=('local', 'cloud', 'both'))
    args = parser.parse_args()
    if args.resolve and (not args.choice or args.dry_run):
        parser.error('--resolve requires --choice and cannot be combined with --dry-run')
    if args.choice and not args.resolve:
        parser.error('--choice requires --resolve')
    local = args.local.resolve()
    cloud = args.cloud.resolve()
    files, conflicts = load_state(args.state, local, cloud)
    if args.resolve:
        return resolve_conflict(args, local, cloud, files, conflicts)
    return sync_files(args, local, cloud, files, conflicts)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f'FAILED\t{error}', file=sys.stderr)
        sys.exit(2)
