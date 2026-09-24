#!/usr/bin/env python3
"""Anchor-based folder sync with recoverable overwrites and optional deletions."""

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
import uuid

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


def backup_root(state_path):
    return state_path.parent / (state_path.stem + '-backups')


def backup_file(state_path, root, name, side, reason, retention_days):
    source = safe_path(root, name)
    before = signature(source)
    if before is None:
        return None
    content_hash = digest(source)
    if signature(source) != before:
        raise OSError('备份期间文件发生变化，已取消覆盖或删除')
    backup_id = uuid.uuid4().hex
    directory = backup_root(state_path) / backup_id
    directory.mkdir(parents=True, exist_ok=False)
    payload = directory / 'content'
    copy_atomic(source, payload, before, None)
    if digest(payload) != content_hash or signature(source) != before:
        raise OSError('备份校验失败，已取消覆盖或删除')
    created = datetime.now(timezone.utc)
    metadata = {'id': backup_id, 'name': name, 'side': side, 'reason': reason,
                'root': str(root), 'createdAt': created.isoformat(),
                'createdAtEpoch': created.timestamp(),
                'retentionDays': retention_days, 'sha256': content_hash,
                'size': before[0]}
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=directory,
                                     prefix='manifest.', delete=False) as target:
        json.dump(metadata, target, ensure_ascii=False, sort_keys=True)
        target.flush()
        os.fsync(target.fileno())
        temporary = Path(target.name)
    os.replace(temporary, directory / 'manifest.json')
    print(f'BACKUP\t{name}\tside={side}\tid={backup_id}\treason={reason}')
    return backup_id


def copy_protected(args, source, destination, source_sig, destination_sig,
                   name, destination_side, reason='overwrite'):
    if destination_sig is not None:
        backup_id = backup_file(args.state, args.local if destination_side == 'local' else args.cloud,
                                name, destination_side, reason, args.backup_retention_days)
        if backup_id:
            args.backup_count += 1
    copy_atomic(source, destination, source_sig, destination_sig)


def delete_protected(args, root, name, side):
    target = safe_path(root, name)
    before = signature(target)
    if before is None:
        return
    backup_id = backup_file(args.state, root, name, side, 'delete', args.backup_retention_days)
    if backup_id:
        args.backup_count += 1
    if signature(target) != before:
        raise OSError('删除前文件发生变化，已取消删除')
    target.unlink()
    print(f'DELETED\t{name}\tside={side}')


def prune_backups(state_path, retention_days):
    root = backup_root(state_path)
    if not root.exists():
        return
    now = datetime.now(timezone.utc)
    for directory in root.iterdir():
        if not directory.is_dir() or directory.is_symlink():
            continue
        manifest = directory / 'manifest.json'
        if not manifest.is_file() or manifest.is_symlink():
            continue
        try:
            data = json.loads(manifest.read_text(encoding='utf-8'))
            created = datetime.fromisoformat(data['createdAt'])
            days = int(data.get('retentionDays', retention_days))
            if (now - created).total_seconds() >= days * 86400:
                shutil.rmtree(directory)
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
            print(f'FAILED\tbackup:{directory.name}\t备份清理失败：{error}')


def restore_backup(args, local, cloud):
    backup_id = args.restore
    if not re.fullmatch(r'[0-9a-f]{32}', backup_id):
        raise ValueError('无效的备份 ID')
    directory = backup_root(args.state) / backup_id
    metadata = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if metadata.get('id') != backup_id or metadata.get('side') not in ('local', 'cloud'):
        raise ValueError('备份信息无效')
    root = local if metadata['side'] == 'local' else cloud
    if metadata.get('root') != str(root):
        raise ValueError('备份对应的同步路径已变更')
    name = metadata['name']
    destination = safe_path(root, name)
    payload = directory / 'content'
    if payload.is_symlink() or digest(payload) != metadata['sha256']:
        raise OSError('备份内容校验失败，已取消恢复')
    existing = signature(destination)
    if existing is not None:
        backup_file(args.state, root, name, metadata['side'], 'restore-overwrite',
                    args.backup_retention_days)
    copy_atomic(payload, destination, signature(payload), existing)
    print(f'RESTORED\t{name}\tside={metadata["side"]}\tfrom={backup_id}')
    return 0


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


def preserve_both(args, local, cloud, name, local_sig, cloud_sig, hashes,
                  backups=None, primary='local'):
    state_path = args.state
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
        copy_protected(args, local_backup, cloud_file, signature(local_backup), cloud_sig,
                       name, 'cloud', 'conflict-overwrite')
    else:
        copy_protected(args, cloud_backup, local_file, signature(cloud_backup), local_sig,
                       name, 'local', 'conflict-overwrite')
    return sidecar_name, backup_dir


def sync_files(args, local, cloud, files, conflicts):
    next_files = dict(files)
    next_conflicts = dict(conflicts)
    errors = []
    names = scan(local, args.exclude_latex, errors) | scan(cloud, args.exclude_latex, errors) | set(files)
    counts = {'uploaded': 0, 'downloaded': 0, 'unchanged': 0,
              'kept_both': 0, 'newest': 0, 'deleted': 0, 'pending_delete': 0, 'backups': 0,
              'skipped': 0, 'conflicts': 0, 'reviews': 0, 'failed': 0}

    def aligned(local_sig, cloud_sig, content_hash):
        return {'local': local_sig, 'cloud': cloud_sig, 'anchorHash': content_hash}

    for name in sorted(names):
        try:
            local_file = safe_path(local, name)
            cloud_file = safe_path(cloud, name)
            local_sig = signature(local_file)
            cloud_sig = signature(cloud_file)
            if local_sig is None and cloud_sig is None:
                if not args.dry_run:
                    next_files.pop(name, None)
                    clear_pending(next_conflicts, name)
                continue
            pending = name in conflicts and not is_review(conflicts[name])
            review = name in conflicts and is_review(conflicts[name])
            previous = files.get(name)
            if local_sig is None or cloud_sig is None:
                if errors:
                    print(f'FAILED\t{name}\t目录扫描有错误，无法确认文件确实已删除')
                    counts['failed'] += 1
                    continue
                upload = cloud_sig is None
                existing_file = local_file if upload else cloud_file
                existing_sig = local_sig if upload else cloud_sig
                existing_side = 'local' if upload else 'cloud'
                missing_side = 'cloud' if upload else 'local'
                existing_hash = digest(existing_file)
                if signature(existing_file) != existing_sig:
                    raise OSError('读取期间文件发生变化，已跳过')
                deletion_direction = args.direction == 'merge' or (
                    args.direction == 'upload' and missing_side == 'local') or (
                    args.direction == 'download' and missing_side == 'cloud')
                if pending:
                    if not args.dry_run:
                        hashes = (existing_hash, None) if upload else (None, existing_hash)
                        next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes,
                                                                'delete_edit')
                    print(f'CONFLICT\t{name}\t删除与编辑冲突，等待选择版本')
                    counts['conflicts'] += 1
                    continue
                if (previous is not None and args.propagate_deletions and deletion_direction
                        and not review):
                    anchor = previous.get('anchorHash')
                    existing_unchanged = (existing_hash == anchor if anchor is not None
                                          else existing_sig == previous.get(existing_side))
                    if existing_unchanged:
                        if previous.get('missingSide') != missing_side:
                            if not args.dry_run:
                                next_files[name] = {**previous, 'missingSide': missing_side,
                                                    'missingSeenAt': datetime.now(timezone.utc).isoformat()}
                            print(f'PENDING_DELETE\t{name}\tmissing={missing_side}')
                            counts['pending_delete'] += 1
                            counts['skipped'] += 1
                        else:
                            if not args.dry_run:
                                delete_protected(args, local if upload else cloud, name, existing_side)
                                next_files.pop(name, None)
                                next_conflicts.pop(name, None)
                            else:
                                print(f'WOULD_DELETE\t{name}\tside={existing_side}')
                            counts['deleted'] += 1
                    else:
                        if not args.dry_run:
                            hashes = (existing_hash, None) if upload else (None, existing_hash)
                            next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes,
                                                                    'delete_edit')
                        print(f'CONFLICT\t{name}\t一侧删除、另一侧编辑，未删除任何文件')
                        counts['conflicts'] += 1
                    continue
                if args.direction != 'merge' and (args.direction == 'upload') != upload:
                    counts['skipped'] += 1
                    continue
                if not args.dry_run:
                    copy_atomic(existing_file, cloud_file if upload else local_file,
                                existing_sig, None)
                    next_files[name] = aligned(signature(local_file), signature(cloud_file),
                                               existing_hash)
                    clear_pending(next_conflicts, name)
                counts['uploaded' if upload else 'downloaded'] += 1
                continue

            if (not pending and previous
                    and local_sig == previous.get('local')
                    and cloud_sig == previous.get('cloud')):
                if review:
                    review_hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                    if review_hashes[0] != review_hashes[1]:
                        raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')
                if previous.get('missingSide') and not args.dry_run:
                    next_files[name] = {key: value for key, value in previous.items()
                                        if key not in ('missingSide', 'missingSeenAt')}
                counts['unchanged'] += 1
                continue

            hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
            if hashes[0] == hashes[1]:
                if not args.dry_run:
                    next_files[name] = aligned(local_sig, cloud_sig, hashes[0])
                    clear_pending(next_conflicts, name)
                counts['unchanged'] += 1
                continue

            anchor = previous.get('anchorHash') if previous else None
            if previous and anchor is None:
                if local_sig == previous.get('local'):
                    anchor = hashes[0]
                elif cloud_sig == previous.get('cloud'):
                    anchor = hashes[1]
            local_changed = previous is None or (
                hashes[0] != anchor if anchor is not None else local_sig != previous.get('local'))
            cloud_changed = previous is None or (
                hashes[1] != anchor if anchor is not None else cloud_sig != previous.get('cloud'))
            if review and local_changed and cloud_changed:
                raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')

            if pending or (local_changed and cloud_changed):
                if args.conflict_policy == 'newest' and not review:
                    if local_sig[1] == cloud_sig[1]:
                        if not args.dry_run:
                            next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes,
                                                                    'same_mtime')
                        print(f'CONFLICT\t{name}\t修改时间相同但内容不同，等待人工选择')
                        counts['conflicts'] += 1
                        continue
                    upload = local_sig[1] > cloud_sig[1]
                    if (upload and args.direction == 'download') or (
                            not upload and args.direction == 'upload'):
                        if not args.dry_run:
                            next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes,
                                                                    'newest_opposes_direction')
                        print(f'CONFLICT\t{name}\t较新版本与指定单向同步方向相反，未覆盖任何一侧')
                        counts['conflicts'] += 1
                        continue
                    if not args.dry_run:
                        copy_protected(args, local_file if upload else cloud_file,
                                       cloud_file if upload else local_file,
                                       local_sig if upload else cloud_sig,
                                       cloud_sig if upload else local_sig,
                                       name, 'cloud' if upload else 'local', 'newest-overwrite')
                        next_files[name] = aligned(signature(local_file), signature(cloud_file),
                                                   hashes[0] if upload else hashes[1])
                        clear_pending(next_conflicts, name)
                        print(f'NEWEST\t{name}\tside={"local" if upload else "cloud"}')
                    else:
                        print(f'WOULD_KEEP_NEWEST\t{name}\tside={"local" if upload else "cloud"}')
                    counts['newest'] += 1
                    counts['uploaded' if upload else 'downloaded'] += 1
                    continue
                if args.conflict_policy == 'keep-both':
                    if not args.dry_run:
                        # Persist the conflict first. A failed backup or cloud write
                        # must leave it visible for a later retry.
                        next_conflicts[name] = conflict_record(
                            local_sig, cloud_sig, hashes,
                            'pending' if pending else ('initial' if previous is None else 'both_changed'))
                        save_state(args.state, local, cloud, next_files, next_conflicts)
                        sidecar_name, backup_dir = preserve_both(
                            args, local, cloud, name, local_sig, cloud_sig, hashes,
                            primary='cloud' if args.direction == 'download' else 'local')
                        next_files[name] = aligned(signature(local_file), signature(cloud_file),
                                                   hashes[1] if args.direction == 'download' else hashes[0])
                        next_files[sidecar_name] = aligned(signature(local / sidecar_name),
                                                           signature(cloud / sidecar_name),
                                                           hashes[0] if args.direction == 'download' else hashes[1])
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

            upload = local_changed and not cloud_changed
            if (upload and args.direction == 'download') or (
                    not upload and args.direction == 'upload'):
                counts['skipped'] += 1
                continue
            if not args.dry_run:
                copy_protected(args, local_file if upload else cloud_file,
                               cloud_file if upload else local_file,
                               local_sig if upload else cloud_sig,
                               cloud_sig if upload else local_sig,
                               name, 'cloud' if upload else 'local')
                next_files[name] = aligned(signature(local_file), signature(cloud_file),
                                           hashes[0] if upload else hashes[1])
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
        prune_backups(args.state, args.backup_retention_days)
    counts['backups'] = args.backup_count
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
    hashes = (digest(local_file) if local_sig is not None else None,
              digest(cloud_file) if cloud_sig is not None else None)
    if hashes != (record['localHash'], record['cloudHash']) or (
            signature(local_file) != local_sig or signature(cloud_file) != cloud_sig):
        raise OSError('冲突文件内容在列出后发生变化；请先重新同步')

    if local_sig is None or cloud_sig is None:
        if args.choice in ('both', 'newest'):
            raise ValueError('删除与编辑冲突请明确选择保留文件的一侧或保留删除')
        source = local_file if args.choice == 'local' else cloud_file
        destination = cloud_file if args.choice == 'local' else local_file
        source_sig = local_sig if args.choice == 'local' else cloud_sig
        destination_sig = cloud_sig if args.choice == 'local' else local_sig
        next_files = dict(files)
        if source_sig is None:
            if destination_sig is not None:
                delete_protected(args, cloud if args.choice == 'local' else local,
                                 name, 'cloud' if args.choice == 'local' else 'local')
            next_files.pop(name, None)
            action = 'deleted'
        else:
            copy_protected(args, source, destination, source_sig, destination_sig,
                           name, 'cloud' if args.choice == 'local' else 'local')
            next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file),
                                'anchorHash': hashes[0] if args.choice == 'local' else hashes[1]}
            action = 'restored'
        next_conflicts = dict(conflicts)
        next_conflicts.pop(name)
        save_state(args.state, local, cloud, next_files, next_conflicts)
        print(f'RESOLVED\t{name}\t{action}')
        return 0

    if args.choice == 'newest':
        if local_sig[1] == cloud_sig[1]:
            raise ValueError('两侧修改时间相同，无法自动选出较新版本')
        args.choice = 'local' if local_sig[1] > cloud_sig[1] else 'cloud'

    backups = backup_pair(args.state, name, local_file, cloud_file,
                          local_sig, cloud_sig, hashes)
    backup_dir, local_backup, cloud_backup = backups

    next_files = dict(files)
    next_conflicts = dict(conflicts)
    sidecar_name = None
    if args.choice == 'local':
        copy_protected(args, local_backup, cloud_file, signature(local_backup), cloud_sig,
                       name, 'cloud', 'conflict-overwrite')
    elif args.choice == 'cloud':
        copy_protected(args, cloud_backup, local_file, signature(cloud_backup), local_sig,
                       name, 'local', 'conflict-overwrite')
    else:
        sidecar_name, _ = preserve_both(args, local, cloud, name,
                                        local_sig, cloud_sig, hashes, backups=backups)
        next_files[sidecar_name] = {'local': signature(local / sidecar_name),
                                    'cloud': signature(cloud / sidecar_name),
                                    'anchorHash': hashes[1]}

    next_files[name] = {'local': signature(local_file), 'cloud': signature(cloud_file),
                        'anchorHash': hashes[1] if args.choice == 'cloud' else hashes[0]}
    if sidecar_name:
        next_conflicts[name] = preserved_record(record, sidecar_name, 'local')
    else:
        next_conflicts.pop(name)
    save_state(args.state, local, cloud, next_files, next_conflicts)
    print(f'{"PRESERVED" if sidecar_name else "RESOLVED"}\t{name}\t{args.choice}\tbackup={backup_dir}'
          + (f'\tcopy={sidecar_name}' if sidecar_name else ''))
    return 0


def resolve_review_newest(args, local, cloud, files, conflicts):
    name = args.review_newest
    record = conflicts.get(name)
    if record is None or not is_review(record):
        raise ValueError(f'没有待确认的已保留版本：{name}')
    primary = record['primary']
    sidecar = record['sidecar']
    primary_sig = record[primary]
    secondary_sig = record['cloud' if primary == 'local' else 'local']
    if primary_sig[1] == secondary_sig[1]:
        raise ValueError('两个原始版本的修改时间相同；请人工检查后选择')
    main_local = safe_path(local, name)
    main_cloud = safe_path(cloud, name)
    copy_local = safe_path(local, sidecar)
    copy_cloud = safe_path(cloud, sidecar)
    if (signature(main_local) != primary_sig or signature(main_cloud) != primary_sig
            or signature(copy_local) != secondary_sig or signature(copy_cloud) != secondary_sig):
        raise OSError('保留版本后来发生变化；请人工检查，未自动覆盖')
    main_hashes = checked_digests(main_local, main_cloud, primary_sig, primary_sig)
    copy_hashes = checked_digests(copy_local, copy_cloud, secondary_sig, secondary_sig)
    if main_hashes[0] != main_hashes[1] or copy_hashes[0] != copy_hashes[1]:
        raise OSError('两侧版本不一致；请人工检查，未自动覆盖')
    winner = primary if primary_sig[1] > secondary_sig[1] else (
        'cloud' if primary == 'local' else 'local')
    if winner != primary:
        copy_protected(args, copy_local, main_local, secondary_sig, primary_sig,
                       name, 'local', 'review-newest-overwrite')
        copy_protected(args, copy_cloud, main_cloud, secondary_sig, primary_sig,
                       name, 'cloud', 'review-newest-overwrite')
    next_files = dict(files)
    next_files[name] = {'local': signature(main_local), 'cloud': signature(main_cloud),
                        'anchorHash': main_hashes[0] if winner == primary else copy_hashes[0]}
    next_conflicts = dict(conflicts)
    next_conflicts.pop(name)
    save_state(args.state, local, cloud, next_files, next_conflicts)
    print(f'REVIEW_NEWEST\t{name}\tside={winner}\tcopy={sidecar}')
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
    next_files[name] = {'local': local_sig, 'cloud': cloud_sig, 'anchorHash': hashes[0]}
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
    parser.add_argument('--conflict-policy', choices=('keep-both', 'ask', 'newest'), default='keep-both')
    parser.add_argument('--propagate-deletions', action='store_true')
    parser.add_argument('--backup-retention-days', type=int, default=15)
    parser.add_argument('--exclude-latex', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--resolve', metavar='RELATIVE_PATH')
    parser.add_argument('--acknowledge', metavar='RELATIVE_PATH')
    parser.add_argument('--review-newest', metavar='RELATIVE_PATH')
    parser.add_argument('--restore', metavar='BACKUP_ID')
    parser.add_argument('--choice', choices=('local', 'cloud', 'both', 'newest'))
    args = parser.parse_args()
    if args.resolve and (not args.choice or args.dry_run):
        parser.error('--resolve requires --choice and cannot be combined with --dry-run')
    if args.choice and not args.resolve:
        parser.error('--choice requires --resolve')
    if args.acknowledge and (args.resolve or args.choice or args.dry_run):
        parser.error('--acknowledge cannot be combined with --resolve, --choice or --dry-run')
    if args.review_newest and (args.resolve or args.acknowledge or args.choice or args.restore or args.dry_run):
        parser.error('--review-newest cannot be combined with other actions or --dry-run')
    if args.restore and (args.resolve or args.acknowledge or args.review_newest or args.choice or args.dry_run):
        parser.error('--restore cannot be combined with sync or resolution options')
    if not 1 <= args.backup_retention_days <= 365:
        parser.error('--backup-retention-days must be between 1 and 365')
    local = args.local.resolve()
    cloud = args.cloud.resolve()
    args.local, args.cloud = local, cloud
    args.backup_count = 0
    files, conflicts = load_state(args.state, local, cloud)
    if args.restore:
        return restore_backup(args, local, cloud)
    if args.review_newest:
        return resolve_review_newest(args, local, cloud, files, conflicts)
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
