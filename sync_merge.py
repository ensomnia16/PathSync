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


def ensure_no_tree_barrier(name, conflicts):
    for directory, record in conflicts.items():
        if record.get('kind') == 'tree' and within_directory(name, directory):
            raise ValueError(f'上级目录「{directory}」仍有目录级冲突；请先整体核对目录')


def preserved_record(original, sidecar, primary):
    return {**original, 'status': 'preserved', 'sidecar': sidecar,
            'primary': primary, 'preservedAt': datetime.now(timezone.utc).isoformat()}


def conflict_sidecar(name, secondary, content_hash):
    relative = Path(name)
    return str(relative.with_name(
        relative.stem + f' ({secondary} conflict {content_hash[:12]})' + relative.suffix))


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


def change_time(path):
    try:
        return path.lstat().st_ctime_ns
    except FileNotFoundError:
        return None


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


def ancestor_directories(name):
    parts = Path(name).parts
    return ('/'.join(parts[:index]) for index in range(1, len(parts)))


def within_directory(name, directory):
    return name.startswith(directory + '/')


def directory_snapshot(root, name, exclude_latex):
    """Read the tracked subtree, including empty directories, or confirm absence."""
    path = safe_path(root, name)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(info.st_mode):
        raise OSError(f'目录被其他类型的项目替代：{path}')
    found_files = {}
    found_dirs = {name}

    def walk_error(error):
        raise error

    for current, dirs, files in os.walk(path, onerror=walk_error):
        kept_dirs = []
        for child in dirs:
            child_path = Path(current) / child
            if child in ALWAYS_EXCLUDE_DIRS or (
                    exclude_latex and any(child.startswith(prefix)
                                          for prefix in LATEX_EXCLUDE_DIRS)):
                continue
            if child_path.is_symlink():
                continue
            kept_dirs.append(child)
            found_dirs.add(child_path.relative_to(root).as_posix())
        dirs[:] = kept_dirs
        for child in files:
            if excluded(child, exclude_latex):
                continue
            child_path = Path(current) / child
            if child_path.is_symlink():
                continue
            before = signature(child_path)
            content_hash = digest(child_path)
            if signature(child_path) != before:
                raise OSError(f'读取目录期间文件发生变化：{child_path}')
            found_files[child_path.relative_to(root).as_posix()] = content_hash
    return {'files': found_files, 'dirs': found_dirs}


def anchor_directory_snapshot(directory, files):
    anchored_files = {
        name: (record.get('anchorHash') or '<unknown-anchor>')
        for name, record in files.items()
        if within_directory(name, directory)
        and (record.get('anchorHash') is not None
             or record.get('local') is not None or record.get('cloud') is not None)}
    anchored_dirs = {directory}
    for name in anchored_files:
        anchored_dirs.update(parent for parent in ancestor_directories(name)
                             if parent == directory or within_directory(parent, directory))
    return {'files': anchored_files, 'dirs': anchored_dirs}


def copy_atomic(source, destination, source_sig, destination_sig,
                expected_source_hash=None, expected_destination_hash=None):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + '.researchsync-partial')
    try:
        source_hash = expected_source_hash or digest(source)
        destination_hash = (expected_destination_hash if expected_destination_hash is not None
                            else digest(destination) if destination_sig is not None else None)
        if (signature(source) != source_sig or signature(destination) != destination_sig
                or digest(source) != source_hash
                or (destination_sig is not None and digest(destination) != destination_hash)):
            raise OSError('文件在复制前发生变化，已跳过本次复制')
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()
        shutil.copy2(source, temporary)
        if (signature(source) != source_sig or signature(destination) != destination_sig
                or digest(source) != source_hash or digest(temporary) != source_hash
                or (destination_sig is not None and digest(destination) != destination_hash)):
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
    source_hash = digest(source)
    destination_hash = digest(destination) if destination_sig is not None else None
    if signature(source) != source_sig or signature(destination) != destination_sig:
        raise OSError('文件在备份前发生变化，已跳过本次复制')
    if destination_sig is not None:
        backup_id = backup_file(args.state, args.local if destination_side == 'local' else args.cloud,
                                name, destination_side, reason, args.backup_retention_days)
        if backup_id:
            args.backup_count += 1
            if json.loads((backup_root(args.state) / backup_id / 'manifest.json').read_text(
                    encoding='utf-8'))['sha256'] != destination_hash:
                raise OSError('目标文件在备份期间发生变化，已取消覆盖')
    copy_atomic(source, destination, source_sig, destination_sig,
                source_hash, destination_hash)


def delete_protected(args, root, name, side):
    target = safe_path(root, name)
    before = signature(target)
    if before is None:
        return
    backup_id = backup_file(args.state, root, name, side, 'delete', args.backup_retention_days)
    if backup_id is None:
        raise OSError('删除前文件已改变，已取消删除')
    args.backup_count += 1
    backed_up_hash = json.loads((backup_root(args.state) / backup_id / 'manifest.json').read_text(
        encoding='utf-8'))['sha256']
    if signature(target) != before or digest(target) != backed_up_hash:
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
    secondary = 'cloud' if primary == 'local' else 'local'
    secondary_hash = hashes[1] if primary == 'local' else hashes[0]
    secondary_backup = cloud_backup if primary == 'local' else local_backup
    sidecar_name = conflict_sidecar(name, secondary, secondary_hash)
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
    names = (scan(local, args.exclude_latex, errors)
             | scan(cloud, args.exclude_latex, errors) | set(files) | set(conflicts))
    counts = {'uploaded': 0, 'downloaded': 0, 'unchanged': 0,
              'kept_both': 0, 'newest': 0, 'deleted': 0, 'backups': 0,
              'skipped': 0, 'conflicts': 0, 'reviews': 0, 'failed': 0}

    def aligned(path_name, local_sig, cloud_sig, content_hash):
        return {'local': local_sig, 'cloud': cloud_sig, 'anchorHash': content_hash,
                'localCtime': change_time(safe_path(local, path_name)),
                'cloudCtime': change_time(safe_path(cloud, path_name))}

    tree_record_names = {name for name, record in conflicts.items()
                         if record.get('kind') == 'tree'}
    blocked_directories = set()

    def blocked(name):
        return any(name == directory or within_directory(name, directory)
                   for directory in blocked_directories)

    # A deletion of a parent and an edit below it is one tree conflict. Resolve
    # existing barriers first, then detect new ones before touching any child.
    for directory in sorted(tree_record_names, key=lambda item: (item.count('/'), item)):
        if blocked(directory):
            continue
        record = conflicts[directory]
        try:
            left = directory_snapshot(local, directory, args.exclude_latex)
            right = directory_snapshot(cloud, directory, args.exclude_latex)
            anchor_tree = anchor_directory_snapshot(directory, files)
            reverted_edit = ((left is None and right == anchor_tree
                              and record.get('deletedSide') == 'local') or
                             (right is None and left == anchor_tree
                              and record.get('deletedSide') == 'cloud'))
            if left == right or reverted_edit:
                if not args.dry_run:
                    next_conflicts.pop(directory, None)
                continue
            blocked_directories.add(directory)
            print(f'CONFLICT\t{directory}\t目录删除与内部修改尚未解决，已暂停整个目录')
            counts['conflicts'] += 1
        except (OSError, ValueError) as error:
            blocked_directories.add(directory)
            print(f'FAILED\t{directory}\t无法核验目录冲突：{error}')
            counts['failed'] += 1

    anchored_directories = {directory for name, record in files.items()
                            if (record.get('anchorHash') is not None
                                or record.get('local') is not None
                                or record.get('cloud') is not None)
                            for directory in ancestor_directories(name)}
    for directory in sorted(anchored_directories, key=lambda item: (item.count('/'), item)):
        if directory in tree_record_names or blocked(directory) or errors:
            continue
        try:
            left_path = safe_path(local, directory)
            right_path = safe_path(cloud, directory)

            def directory_exists(path):
                try:
                    info = path.lstat()
                except FileNotFoundError:
                    return False
                if not stat.S_ISDIR(info.st_mode):
                    raise OSError(f'目录被其他类型的项目替代：{path}')
                return True

            left_exists = directory_exists(left_path)
            right_exists = directory_exists(right_path)
            if left_exists == right_exists:
                continue
            deleted_side = 'cloud' if left_exists else 'local'
            surviving_root = local if left_exists else cloud
            surviving = directory_snapshot(surviving_root, directory, args.exclude_latex)
            if surviving == anchor_directory_snapshot(directory, files):
                continue
            blocked_directories.add(directory)
            tree_record_names.add(directory)
            if not args.dry_run:
                next_conflicts[directory] = {
                    'kind': 'tree', 'reason': 'directory_delete_edit',
                    'deletedSide': deleted_side,
                    'local': None, 'cloud': None,
                    'detectedAt': datetime.now(timezone.utc).isoformat()}
            print(f'CONFLICT\t{directory}\t目录删除与内部修改冲突，已暂停整个目录')
            counts['conflicts'] += 1
        except (OSError, ValueError) as error:
            blocked_directories.add(directory)
            print(f'FAILED\t{directory}\t无法核验目录状态：{error}')
            counts['failed'] += 1

    for name in sorted(names):
        if name in tree_record_names:
            continue
        if blocked(name):
            counts['skipped'] += 1
            continue
        try:
            local_file = safe_path(local, name)
            cloud_file = safe_path(cloud, name)
            local_sig = signature(local_file)
            cloud_sig = signature(cloud_file)
            # A failed directory scan cannot establish absence, even when both
            # current path lookups happen to report a missing file.
            if errors and (local_sig is None or cloud_sig is None):
                print(f'FAILED\t{name}\t目录扫描有错误，无法确认文件确实已删除')
                counts['failed'] += 1
                continue
            previous = files.get(name)
            pending = name in conflicts and not is_review(conflicts[name])
            review = name in conflicts and is_review(conflicts[name])
            if local_sig is None and cloud_sig is None:
                if review or conflicts.get(name, {}).get('status') == 'preserving':
                    raise OSError('待合并的主文件两侧都已缺失；请先检查冲突副本')
                if not args.dry_run:
                    if previous is not None:
                        next_files[name] = aligned(name, None, None, None)
                    clear_pending(next_conflicts, name)
                continue

            if review and (local_sig is None or cloud_sig is None):
                raise OSError('待合并的主文件缺失；请先人工检查，未覆盖任何一侧')

            if (not pending and previous and local_sig is not None and cloud_sig is not None
                    and local_sig == previous.get('local')
                    and cloud_sig == previous.get('cloud')
                    and previous.get('localCtime') == change_time(local_file)
                    and previous.get('cloudCtime') == change_time(cloud_file)):
                if review:
                    review_hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                    if review_hashes[0] != review_hashes[1]:
                        raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')
                counts['unchanged'] += 1
                continue

            if local_sig is not None and cloud_sig is not None:
                hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
            else:
                hashes = (digest(local_file) if local_sig is not None else None,
                          digest(cloud_file) if cloud_sig is not None else None)
                if signature(local_file) != local_sig or signature(cloud_file) != cloud_sig:
                    raise OSError('文件在读取过程中发生变化，已跳过本次比较')
            if hashes[0] == hashes[1]:
                preserving = conflicts.get(name, {})
                if preserving.get('status') == 'preserving':
                    primary = preserving['primary']
                    sidecar = preserving['sidecar']
                    expected_main = preserving[primary + 'Hash']
                    expected_copy = preserving[('cloud' if primary == 'local' else 'local') + 'Hash']
                    if hashes[0] != expected_main or any(
                            signature(safe_path(root, sidecar)) is None
                            or digest(safe_path(root, sidecar)) != expected_copy
                            for root in (local, cloud)):
                        raise OSError('中断的冲突保留尚未完成；请重新同步，未清除待处理记录')
                    if not args.dry_run:
                        next_files[sidecar] = aligned(sidecar, signature(local / sidecar),
                                                      signature(cloud / sidecar), expected_copy)
                        next_conflicts[name] = preserved_record(preserving, sidecar, primary)
                if not args.dry_run:
                    next_files[name] = aligned(name, local_sig, cloud_sig, hashes[0])
                    clear_pending(next_conflicts, name)
                counts['unchanged'] += 1
                continue

            anchor = previous.get('anchorHash') if previous else None
            if previous and anchor is None and (
                    previous.get('local') is not None or previous.get('cloud') is not None):
                if local_sig == previous.get('local'):
                    anchor = hashes[0]
                elif cloud_sig == previous.get('cloud'):
                    anchor = hashes[1]
                else:
                    # Old state without an anchor cannot identify a winner.
                    anchor = object()
            local_changed = hashes[0] != anchor
            cloud_changed = hashes[1] != anchor
            if review and local_changed and cloud_changed:
                raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')

            if local_changed and cloud_changed:
                if (args.conflict_policy == 'newest' and not review
                        and local_sig is not None and cloud_sig is not None):
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
                        next_files[name] = aligned(name, signature(local_file), signature(cloud_file),
                                                   hashes[0] if upload else hashes[1])
                        clear_pending(next_conflicts, name)
                        print(f'NEWEST\t{name}\tside={"local" if upload else "cloud"}')
                    else:
                        print(f'WOULD_KEEP_NEWEST\t{name}\tside={"local" if upload else "cloud"}')
                    counts['newest'] += 1
                    counts['uploaded' if upload else 'downloaded'] += 1
                    continue
                if (args.conflict_policy == 'keep-both' and local_sig is not None
                        and cloud_sig is not None):
                    if not args.dry_run:
                        # Persist the conflict first. A failed backup or cloud write
                        # must leave it visible for a later retry.
                        primary = (conflicts[name].get('primary') if pending else None) or (
                            'cloud' if args.direction == 'download' else 'local')
                        secondary = 'cloud' if primary == 'local' else 'local'
                        sidecar_intent = conflict_sidecar(
                            name, secondary, hashes[1] if primary == 'local' else hashes[0])
                        next_conflicts[name] = {
                            **conflict_record(local_sig, cloud_sig, hashes,
                                              'pending' if pending else (
                                                  'initial' if previous is None else 'both_changed')),
                            'status': 'preserving', 'primary': primary,
                            'sidecar': sidecar_intent}
                        save_state(args.state, local, cloud, next_files, next_conflicts)
                        sidecar_name, backup_dir = preserve_both(
                            args, local, cloud, name, local_sig, cloud_sig, hashes,
                            primary=primary)
                        next_files[name] = aligned(name, signature(local_file), signature(cloud_file),
                                                   hashes[0] if primary == 'local' else hashes[1])
                        next_files[sidecar_name] = aligned(sidecar_name, signature(local / sidecar_name),
                                                           signature(cloud / sidecar_name),
                                                           hashes[1] if primary == 'local' else hashes[0])
                        next_conflicts[name] = preserved_record(
                            next_conflicts[name], sidecar_name, primary)
                        print(f'KEPT_BOTH\t{name}\tcopy={sidecar_name}\tbackup={backup_dir}')
                    else:
                        print(f'WOULD_KEEP_BOTH\t{name}')
                    counts['kept_both'] += 1
                else:
                    reason = ('delete_edit' if local_sig is None or cloud_sig is None else
                              'pending' if pending else
                              'initial' if previous is None else 'both_changed')
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
            source_sig = local_sig if upload else cloud_sig
            if not args.dry_run:
                if source_sig is None:
                    delete_protected(args, cloud if upload else local, name,
                                     'cloud' if upload else 'local')
                    next_files[name] = aligned(name, None, None, None)
                else:
                    copy_protected(args, local_file if upload else cloud_file,
                                   cloud_file if upload else local_file,
                                   source_sig, cloud_sig if upload else local_sig,
                                   name, 'cloud' if upload else 'local')
                    next_files[name] = aligned(name, signature(local_file), signature(cloud_file),
                                               hashes[0] if upload else hashes[1])
                clear_pending(next_conflicts, name)
            else:
                if source_sig is None:
                    print(f'WOULD_DELETE\t{name}\tside={"cloud" if upload else "local"}')
            counts['deleted' if source_sig is None else 'uploaded' if upload else 'downloaded'] += 1
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
    ensure_no_tree_barrier(name, conflicts)
    if name not in conflicts:
        raise ValueError(f'没有待处理冲突：{name}')
    record = conflicts[name]
    if record.get('kind') == 'tree':
        raise ValueError('这是目录级冲突；请先在文件管理器中核对整个目录，使两侧内容一致或都删除，随后重新同步')
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
            next_files[name] = {'local': None, 'cloud': None, 'anchorHash': None}
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
    ensure_no_tree_barrier(name, conflicts)
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
    ensure_no_tree_barrier(name, conflicts)
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
