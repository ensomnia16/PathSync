#!/usr/bin/env python3
"""Non-deleting folder sync with explicit, recoverable conflict resolution."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile

from sync_tree import ALWAYS_EXCLUDE_DIRS, LATEX_EXCLUDE_DIRS, excluded


SIDECAR_PATTERN = re.compile(r'^(.*) \((cloud|local) conflict ([0-9a-f]{12})\)(\.[^/]*)?$')


def is_review(record):
    return record.get('status') == 'preserved'


def clear_pending(conflicts, name):
    if name in conflicts and not is_review(conflicts[name]):
        conflicts.pop(name)


def preserved_record(original, sidecar, primary):
    return {**original, 'status': 'preserved', 'sidecar': sidecar,
            'primary': primary, 'preservedAt': datetime.now(timezone.utc).isoformat()}


def migrate_old_sidecars(files, conflicts):
    for name, sidecar_state in files.items():
        relative = Path(name)
        match = SIDECAR_PATTERN.fullmatch(relative.name)
        if not match:
            continue
        stem, secondary, _, suffix = match.groups()
        original = relative.with_name(stem + (suffix or '')).as_posix()
        original_state = files.get(original)
        if not original_state or original in conflicts:
            continue
        if (original_state.get('local') != original_state.get('cloud')
                or sidecar_state.get('local') != sidecar_state.get('cloud')):
            continue
        primary = 'local' if secondary == 'cloud' else 'cloud'
        conflicts[original] = {
            'local': original_state['local'] if primary == 'local' else sidecar_state['local'],
            'cloud': sidecar_state['cloud'] if primary == 'local' else original_state['cloud'],
            'status': 'preserved', 'sidecar': name, 'primary': primary,
            'reason': 'migrated preserved versions',
            'preservedAt': datetime.now(timezone.utc).isoformat()}


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
    if not data.get('reviewsInitialized', False):
        migrate_old_sidecars(files, conflicts)
    return files, conflicts


def save_state(path, local, cloud, files, conflicts):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {'version': 1, 'local': str(local), 'cloud': str(cloud),
            'files': files, 'conflicts': conflicts, 'reviewsInitialized': True}
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


def backup_original(source, destination, expected_hash):
    if destination.exists():
        if digest(destination) != expected_hash:
            raise OSError(f'备份文件与预期不同：{destination}')
        return
    copy_atomic(source, destination, signature(source), None)
    if digest(destination) != expected_hash:
        raise OSError(f'备份文件校验失败：{destination}')


def backup_pair(state_path, name, local_file, cloud_file, local_sig, cloud_sig, hashes):
    key = hashlib.sha256(name.encode('utf-8')).hexdigest()[:16]
    version = hashes[0][:12] + '-' + hashes[1][:12]
    backup_dir = state_path.parent / (state_path.stem + '-conflict-backups') / key / version
    suffix = local_file.suffix
    local_backup = backup_dir / ('local' + suffix)
    cloud_backup = backup_dir / ('cloud' + suffix)
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_original(local_file, local_backup, hashes[0])
    backup_original(cloud_file, cloud_backup, hashes[1])
    if checked_digests(local_file, cloud_file, local_sig, cloud_sig) != hashes:
        raise OSError('备份期间文件发生变化；请重新同步')
    return backup_dir, local_backup, cloud_backup


def preserve_both(state_path, local, cloud, name, local_sig, cloud_sig, hashes,
                  backups=None, primary='local'):
    local_file = safe_path(local, name)
    cloud_file = safe_path(cloud, name)
    backup_dir, local_backup, cloud_backup = backups or backup_pair(
        state_path, name, local_file, cloud_file, local_sig, cloud_sig, hashes)
    relative = Path(name)
    secondary = 'cloud' if primary == 'local' else 'local'
    secondary_hash = hashes[1] if primary == 'local' else hashes[0]
    secondary_backup = cloud_backup if primary == 'local' else local_backup
    sidecar_name = str(relative.with_name(
        relative.stem + f' ({secondary} conflict {secondary_hash[:12]})' + relative.suffix))
    local_sidecar = safe_path(local, sidecar_name)
    cloud_sidecar = safe_path(cloud, sidecar_name)
    for target in (cloud_sidecar, local_sidecar):
        if signature(target) is not None and digest(target) != secondary_hash:
            raise OSError(f'冲突副本名称已被其他文件占用：{target}')
    for target in (cloud_sidecar, local_sidecar):
        if signature(target) is None:
            copy_atomic(secondary_backup, target, signature(secondary_backup), None)
    if checked_digests(local_file, cloud_file, local_sig, cloud_sig) != hashes:
        raise OSError('创建冲突副本期间原文件发生变化；请重新同步')
    if primary == 'local':
        copy_atomic(local_backup, cloud_file, signature(local_backup), cloud_sig)
    else:
        copy_atomic(cloud_backup, local_file, signature(cloud_backup), local_sig)
    return sidecar_name, backup_dir


def sync_files(args, local, cloud, files, conflicts):
    next_files = dict(files)
    next_conflicts = dict(conflicts)
    errors = []
    names = scan(local, args.exclude_latex, errors) | scan(cloud, args.exclude_latex, errors)
    counts = {'uploaded': 0, 'downloaded': 0, 'unchanged': 0,
              'kept_both': 0, 'skipped': 0, 'conflicts': 0, 'reviews': 0, 'failed': 0}

    for name in sorted(names):
        try:
            local_file = safe_path(local, name)
            cloud_file = safe_path(cloud, name)
            local_sig = signature(local_file)
            cloud_sig = signature(cloud_file)
            if local_sig is None and cloud_sig is None:
                continue
            pending = name in conflicts and not is_review(conflicts[name])
            review = name in conflicts and is_review(conflicts[name])
            if pending and (local_sig is None or cloud_sig is None):
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
                    clear_pending(next_conflicts, name)
                counts['uploaded' if upload else 'downloaded'] += 1
                continue

            previous = files.get(name)
            if (not pending and previous
                    and local_sig == previous.get('local')
                    and cloud_sig == previous.get('cloud')):
                if review:
                    review_hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                    if review_hashes[0] != review_hashes[1]:
                        raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')
                counts['unchanged'] += 1
                continue

            local_changed = previous is None or local_sig != previous.get('local')
            cloud_changed = previous is None or cloud_sig != previous.get('cloud')
            if pending or (local_changed and cloud_changed) or local_sig == cloud_sig:
                hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                if hashes[0] == hashes[1]:
                    if not args.dry_run:
                        next_files[name] = {'local': local_sig, 'cloud': cloud_sig}
                        clear_pending(next_conflicts, name)
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
                            clear_pending(next_conflicts, name)
                        counts['unchanged'] += 1
                        continue
                if review:
                    raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')
                if args.conflict_policy == 'keep-both':
                    if not args.dry_run:
                        # Persist the conflict first. A failed backup or cloud write
                        # must leave it visible for a later retry.
                        next_conflicts[name] = conflict_record(
                            local_sig, cloud_sig, hashes,
                            'pending' if pending else ('initial' if previous is None else 'both_changed'))
                        save_state(args.state, local, cloud, next_files, next_conflicts)
                        sidecar_name, backup_dir = preserve_both(
                            args.state, local, cloud, name, local_sig, cloud_sig, hashes,
                            primary='cloud' if args.direction == 'download' else 'local')
                        next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
                        next_files[sidecar_name] = {
                            'local': signature(local / sidecar_name),
                            'cloud': signature(cloud / sidecar_name)}
                        next_conflicts[name] = preserved_record(
                            next_conflicts[name], sidecar_name,
                            'cloud' if args.direction == 'download' else 'local')
                        print(f'KEPT_BOTH\t{name}\tcopy={sidecar_name}\tbackup={backup_dir}')
                    else:
                        print(f'WOULD_KEEP_BOTH\t{name}')
                    counts['kept_both'] += 1
                else:
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
                clear_pending(next_conflicts, name)
            counts['uploaded' if upload else 'downloaded'] += 1
        except (OSError, ValueError) as error:
            print(f'FAILED\t{name}\t{error}')
            counts['failed'] += 1

    for path, error in errors:
        print(f'FAILED\t{path}\t{error}')
        counts['failed'] += 1
    for name, record in sorted(next_conflicts.items()):
        if is_review(record):
            print(f'NEEDS_REVIEW\t{name}\tcopy={record["sidecar"]}')
            counts['reviews'] += 1
            try:
                if (signature(safe_path(local, record['sidecar'])) is None
                        or signature(safe_path(cloud, record['sidecar'])) is None):
                    raise OSError('待合并的冲突副本缺失；请检查本地备份')
            except (OSError, ValueError) as error:
                print(f'FAILED\t{record["sidecar"]}\t{error}')
                counts['failed'] += 1
    if not args.dry_run:
        save_state(args.state, local, cloud, next_files, next_conflicts)
        counts['conflicts'] = sum(not is_review(record) for record in next_conflicts.values())
    print(' '.join(f'{key}={value}' for key, value in counts.items()))
    return 2 if counts['conflicts'] or counts['failed'] else 0


def resolve_conflict(args, local, cloud, files, conflicts):
    name = args.resolve
    if name not in conflicts:
        raise ValueError(f'没有待处理冲突：{name}')
    record = conflicts[name]
    if is_review(record):
        raise ValueError('两个版本已经保留，仍待人工合并或确认；请使用 --acknowledge')
    local_file = safe_path(local, name)
    cloud_file = safe_path(cloud, name)
    local_sig = signature(local_file)
    cloud_sig = signature(cloud_file)
    if local_sig != record['local'] or cloud_sig != record['cloud']:
        raise OSError('冲突文件在列出后又发生变化；请先重新同步，再选择版本')
    hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
    if hashes != (record['localHash'], record['cloudHash']):
        raise OSError('冲突文件内容在列出后发生变化；请先重新同步')

    backups = backup_pair(args.state, name, local_file, cloud_file,
                          local_sig, cloud_sig, hashes)
    backup_dir, local_backup, cloud_backup = backups

    next_files = dict(files)
    next_conflicts = dict(conflicts)
    sidecar_name = None
    if args.choice == 'local':
        copy_atomic(local_backup, cloud_file, signature(local_backup), cloud_sig)
    elif args.choice == 'cloud':
        copy_atomic(cloud_backup, local_file, signature(cloud_backup), local_sig)
    else:
        sidecar_name, _ = preserve_both(args.state, local, cloud, name,
                                        local_sig, cloud_sig, hashes, backups=backups)
        next_files[sidecar_name] = {'local': signature(local / sidecar_name),
                                    'cloud': signature(cloud / sidecar_name)}

    next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file)}
    if sidecar_name:
        next_conflicts[name] = preserved_record(record, sidecar_name, 'local')
    else:
        next_conflicts.pop(name)
    save_state(args.state, local, cloud, next_files, next_conflicts)
    print(f'{"PRESERVED" if sidecar_name else "RESOLVED"}\t{name}\t{args.choice}\tbackup={backup_dir}'
          + (f'\tcopy={sidecar_name}' if sidecar_name else ''))
    return 0


def acknowledge_review(args, local, cloud, files, conflicts):
    name = args.acknowledge
    record = conflicts.get(name)
    if record is None or not is_review(record):
        raise ValueError(f'没有待确认的已保留版本：{name}')
    local_file = safe_path(local, name)
    cloud_file = safe_path(cloud, name)
    local_sig = signature(local_file)
    cloud_sig = signature(cloud_file)
    if local_sig is None or cloud_sig is None:
        raise OSError('两侧主文件必须存在，请先同步后再确认')
    hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
    if hashes[0] != hashes[1]:
        raise OSError('两侧主文件内容不同，请先同步或人工合并后再确认')
    next_files = dict(files)
    next_files[name] = {'local': local_sig, 'cloud': cloud_sig}
    next_conflicts = dict(conflicts)
    next_conflicts.pop(name)
    save_state(args.state, local, cloud, next_files, next_conflicts)
    print(f'ACKNOWLEDGED\t{name}\tcopy={record["sidecar"]}')
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local', type=Path)
    parser.add_argument('cloud', type=Path)
    parser.add_argument('state', type=Path)
    parser.add_argument('--direction', choices=('merge', 'upload', 'download'), default='merge')
    parser.add_argument('--conflict-policy', choices=('keep-both', 'ask'), default='keep-both')
    parser.add_argument('--exclude-latex', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--resolve', metavar='RELATIVE_PATH')
    parser.add_argument('--acknowledge', metavar='RELATIVE_PATH')
    parser.add_argument('--choice', choices=('local', 'cloud', 'both'))
    args = parser.parse_args()
    if args.resolve and (not args.choice or args.dry_run):
        parser.error('--resolve requires --choice and cannot be combined with --dry-run')
    if args.choice and not args.resolve:
        parser.error('--choice requires --resolve')
    if args.acknowledge and (args.resolve or args.choice or args.dry_run):
        parser.error('--acknowledge cannot be combined with --resolve, --choice or --dry-run')
    local = args.local.resolve()
    cloud = args.cloud.resolve()
    files, conflicts = load_state(args.state, local, cloud)
    if args.resolve:
        return resolve_conflict(args, local, cloud, files, conflicts)
    if args.acknowledge:
        return acknowledge_review(args, local, cloud, files, conflicts)
    return sync_files(args, local, cloud, files, conflicts)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f'FAILED\t{error}', file=sys.stderr)
        sys.exit(2)
