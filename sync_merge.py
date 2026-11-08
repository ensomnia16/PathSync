#!/usr/bin/env python3
"""Anchor-based folder sync with recoverable overwrites and optional deletions."""

import argparse
from collections import deque
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, TimeoutError as FutureTimeout, wait
from datetime import datetime, timezone
import ctypes
import hashlib
import json
import os
import signal
import subprocess
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
from sync_tree import IGNORE_FILE, ExcludeRules, excluded_relative, load_exclude_rules
import cloud_only
import graph_index


SIDECAR_PATTERN = re.compile(r'^(.*) \((cloud|local) conflict ([0-9a-f]{12})\)(\.[^/]*)?$')
FILE_READ_TIMEOUT_SECONDS = 60
ALLOW_ONLINE_DOWNLOADS = False


def enable_cloud_materialization(enabled=True):
    """Opt this real sync process into reading macOS File Provider placeholders.

    launchd jobs inherit the system default (off), unlike GUI-launched jobs.
    Child readers and worker threads inherit this process policy. This changes
    download behavior, not filesystem access permissions; previews never opt in.
    Constants are from Darwin sys/resource.h and setiopolicy_np(3).
    """
    if sys.platform != 'darwin':
        return
    library = ctypes.CDLL(None, use_errno=True)
    set_policy = library.setiopolicy_np
    set_policy.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int)
    set_policy.restype = ctypes.c_int
    # IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, process scope, ON=2 / OFF=1
    if set_policy(3, 0, 2 if enabled else 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, '无法设置云端文件按需下载策略：' + os.strerror(error))


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


SF_DATALESS = 0x40000000


def is_dataless(path):
    """True for an online-only placeholder whose content the provider must download first."""
    try:
        return bool(getattr(path.lstat(), 'st_flags', 0) & SF_DATALESS)
    except OSError:
        return False


def change_time(path):
    try:
        return path.lstat().st_ctime_ns
    except FileNotFoundError:
        return None


def unchanged_metadata(current, previous, cloud=False):
    if current is None or previous is None or current[0] != previous[0]:
        return False
    # OneDrive's File Provider may restore a file with its mtime rounded down
    # to whole seconds and a fresh ctime, without changing its content.
    tolerance = 1_000_000_000 if cloud else 0
    return abs(current[1] - previous[1]) < tolerance if cloud else current[1] == previous[1]


def digest(path):
    if not ALLOW_ONLINE_DOWNLOADS and is_dataless(path):
        raise OSError('仅在线文件未下载，已保留文件与基线；只需云端保留可将对应子目录设为仅云端（也会暂停上传），需要本地副本则在 OneDrive 下载所选文件后重试')
    hasher = hashlib.sha256()
    previous_alarm = signal.getsignal(signal.SIGALRM)

    def deadline(_signal, _frame):
        raise TimeoutError(f'读取文件超过 {FILE_READ_TIMEOUT_SECONDS} 秒：{path}')

    signal.signal(signal.SIGALRM, deadline)
    signal.setitimer(signal.ITIMER_REAL, FILE_READ_TIMEOUT_SECONDS)
    try:
        with path.open('rb') as source:
            while chunk := source.read(1024 * 1024):
                hasher.update(chunk)
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_alarm)
    return hasher.hexdigest()


def checked_digests(local_file, cloud_file, local_sig, cloud_sig):
    local_hash = digest(local_file)
    cloud_hash = digest(cloud_file)
    if signature(local_file) != local_sig or signature(cloud_file) != cloud_sig:
        raise OSError('文件读取期间发生变化；请在编辑或编译结束后重试，本次未覆盖')
    return local_hash, cloud_hash


def excluded_path(name, args, directory=False):
    if cloud_only.contains(name, getattr(args, 'cloud_only', ())):
        return True
    if name == IGNORE_FILE and not directory:
        return args.shared_excludes
    if args.shared_excludes:
        # Shared configuration supplies every data filter. Keep only our own
        # in-progress transfer files out of the protocol; legacy presets and
        # flags must not silently hide logs, source, settings or whole folders.
        return ((not directory and Path(name).name.endswith('.researchsync-partial'))
                or args.exclude_rules.matches(name, directory=directory))
    return (excluded_relative(name, args.exclude_latex, args.skip_codex,
                              args.skip_claude, args.include_temp, directory=directory)
            or args.exclude_rules.matches(name, directory=directory))


def scan(root, args, errors, symlinks=None):
    found = set()
    scanned = 0
    side = 'local' if root == args.local else 'cloud'
    print(f'PROGRESS\tSCAN\t{side}\t0\t0', flush=True)

    def entries(current):
        directories, files = [], []
        with os.scandir(current) as iterator:
            for entry in iterator:
                relative = (current / entry.name).relative_to(root).as_posix()
                if entry.is_symlink():
                    if symlinks is not None and not excluded_path(relative, args):
                        symlinks.add(relative)
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if not excluded_path(relative, args, directory=True):
                        directories.append(current / entry.name)
                elif not excluded_path(relative, args):
                    files.append(relative)
        return directories, files

    # File Provider directory reads release the GIL while waiting for OneDrive.
    # A few independent reads avoid making every directory wait behind one slow read.
    with ThreadPoolExecutor(max_workers=4) as executor:
        pending = {executor.submit(entries, root): root}
        while pending:
            completed, _ = wait(pending, return_when=FIRST_COMPLETED)
            for future in completed:
                current = pending.pop(future)
                scanned += 1
                try:
                    directories, files = future.result()
                except OSError as error:
                    errors.append((str(current), str(error)))
                    continue
                found.update(files)
                for directory in directories:
                    pending[executor.submit(entries, directory)] = directory
            if scanned % 8 == 0:
                print(f'PROGRESS\tSCAN\t{side}\t{scanned}\t{len(found)}', flush=True)
    print(f'PROGRESS\tSCAN_DONE\t{side}\t{scanned}\t{len(found)}', flush=True)
    return found


class CloudPrefetch:
    """Hydrate cloud-only files ahead of the merge without delaying its first copy."""

    def __init__(self, root, names, online_only=(), order=None):
        # Many new files, or any online-only file the merge must read, are
        # downloaded ahead in parallel with a bounded wait for each.
        candidates = set(names if len(names) >= 100 else ()) | set(online_only)
        self.names = [name for name in (order if order is not None else
                                       list(dict.fromkeys(list(names) + list(online_only))))
                      if name in candidates]
        self.root = root
        self.queue = deque(self.names)
        self.executor = ThreadPoolExecutor(max_workers=4) if self.names else None
        self.futures = {}
        self.completed = 0
        if self.executor:
            print(f'PROGRESS\tPREFETCH\t0\t{len(self.names)}', flush=True)
            self.fill()

    def fill(self):
        # Follow merge order and keep only four downloads queued. A file being
        # processed must never sit behind thousands of unrelated placeholders.
        while self.queue and len(self.futures) < 4:
            name = self.queue.popleft()
            self.futures[name] = self.executor.submit(self.hydrate, self.root / name)

    @staticmethod
    def hydrate(path):
        script = ('import sys\n'
                  'try:\n'
                  '    with open(sys.argv[1], "rb") as source:\n'
                  '        while source.read(1024 * 1024): pass\n'
                  'except OSError as error:\n'
                  '    print("云端文件暂不可读：" + str(error), file=sys.stderr)\n'
                  '    sys.exit(1)\n')
        try:
            # The provider may need to download the complete placeholder. Give
            # large media more time without allowing one file to wait forever.
            timeout = min(300, 120 + path.stat().st_size // 1_000_000)
            result = subprocess.run([sys.executable, '-c', script, str(path)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                    timeout=timeout, check=False)
            if result.returncode != 0:
                return result.stderr.decode('utf-8', 'replace').strip()[-300:] or '无法读取云端文件'
            return None
        except subprocess.TimeoutExpired:
            return f'云端文件读取超过 {timeout} 秒'
        except OSError as error:
            return str(error)

    def check(self, name):
        future = self.futures.get(name)
        if future is None:
            return None
        started = time.monotonic()
        while True:
            try:
                error = future.result(timeout=20)
                break
            except FutureTimeout:
                elapsed = int(time.monotonic() - started)
                print(f'PROGRESS\tWAIT\t{name}\t{elapsed}', flush=True)
                if elapsed >= 320:
                    future.cancel()
                    error = '云端文件等待超过 320 秒；保留两端文件与基线，下次重试'
                    break
        self.futures.pop(name)
        self.fill()
        self.completed += 1
        if self.completed % 8 == 0 or self.completed == len(self.names):
            print(f'PROGRESS\tPREFETCH\t{self.completed}\t{len(self.names)}', flush=True)
        return error

    def close(self):
        if self.executor:
            self.executor.shutdown(wait=False, cancel_futures=True)


def ancestor_directories(name):
    parts = Path(name).parts
    return ('/'.join(parts[:index]) for index in range(1, len(parts)))


def within_directory(name, directory):
    return name.startswith(directory + '/')


def directory_snapshot(root, name, args):
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
            if excluded_path(child_path.relative_to(root).as_posix(), args,
                             directory=True):
                continue
            if child_path.is_symlink():
                continue
            kept_dirs.append(child)
            found_dirs.add(child_path.relative_to(root).as_posix())
        dirs[:] = kept_dirs
        for child in files:
            child_path = Path(current) / child
            if excluded_path(child_path.relative_to(root).as_posix(), args):
                continue
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


def conflict_backup_root(state_path):
    return state_path.parent / (state_path.stem + '-conflict-backups')


PENDING_MOVE = '.pending-move'


def within_or_same(path, other):
    return path == other or str(path).startswith(str(other).rstrip('/') + '/')


class BackupPlace:
    """Where this pair's backups live: beside the merge state, or in a chosen folder.

    A chosen folder (iCloud Drive, OneDrive, ...) may be offline. A backup is
    then kept beside the merge state with a marker and moved on a later run;
    restore and retention cleanup look in both places."""

    def __init__(self, args):
        self.local = {'backups': backup_root(args.state),
                      'conflict-backups': conflict_backup_root(args.state)}
        self.remote = None
        self.available = False
        self.dry_run = args.dry_run
        self.written = {}
        if args.backup_root is None:
            return
        relative = Path(args.backup_subpath or '')
        if relative.is_absolute() or not relative.parts or '..' in relative.parts:
            raise ValueError('备份子目录无效')
        base = Path(args.backup_root).resolve()
        self.remote = base / relative
        for sync_root in (args.local, args.cloud):
            if within_or_same(self.remote, sync_root) or within_or_same(sync_root, self.remote):
                raise ValueError('备份位置不能位于同步路径内，也不能包含同步路径')
        # Never create the chosen folder itself: a missing OneDrive mount would
        # otherwise turn into an ordinary local folder at the same path.
        self.available = base.is_dir() and os.access(base, os.W_OK)

    def targets(self, kind):
        if self.available and not self.dry_run:
            return [(self.remote / kind, True), (self.local[kind], False)]
        return [(self.local[kind], False)]

    def pending(self):
        return self.remote is not None

    def failed(self, error):
        if self.available:
            print(f'BACKUP_FALLBACK\t{self.remote}\t备份位置暂不可用，先存放在本机：{error}')
        self.available = False

    def roots(self, kind):
        found = [self.local[kind]]
        if self.remote is not None and self.available:
            found.insert(0, self.remote / kind)
        return found

    def find(self, backup_id):
        if backup_id in self.written:
            return self.written[backup_id]
        candidates = [self.local['backups'] / backup_id]
        if self.remote is not None:
            candidates.insert(0, self.remote / 'backups' / backup_id)
        for directory in candidates:
            if (directory / 'manifest.json').is_file() and not directory.is_symlink():
                return directory
        return None


def write_backup(directory, source, before, content_hash, metadata, remote, pending):
    directory.mkdir(parents=True, exist_ok=False)
    try:
        payload = directory / 'content'
        copy_atomic(source, payload, before, None)
        if digest(payload) != content_hash or signature(source) != before:
            raise OSError('备份校验失败，已取消覆盖或删除')
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=directory,
                                         prefix='manifest.', delete=False) as target:
            json.dump(metadata, target, ensure_ascii=False, sort_keys=True)
            target.flush()
            os.fsync(target.fileno())
            temporary = Path(target.name)
        os.replace(temporary, directory / 'manifest.json')
        written = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
        if written.get('sha256') != content_hash or digest(payload) != content_hash:
            raise OSError('备份写入后校验失败')
        if pending:
            (directory / PENDING_MOVE).write_text('', encoding='utf-8')
    except BaseException:
        if remote:
            shutil.rmtree(directory, ignore_errors=True)
        raise


def backup_file(args, root, name, side, reason, retention_days):
    source = safe_path(root, name)
    before = signature(source)
    if before is None:
        return None
    content_hash = digest(source)
    if signature(source) != before:
        raise OSError('备份期间文件发生变化，已取消覆盖或删除')
    backup_id = uuid.uuid4().hex
    created = datetime.now(timezone.utc)
    metadata = {'id': backup_id, 'name': name, 'side': side, 'reason': reason,
                'root': str(root), 'createdAt': created.isoformat(),
                'createdAtEpoch': created.timestamp(),
                'retentionDays': retention_days, 'sha256': content_hash,
                'size': before[0]}
    place = args.backups
    for target_root, remote in place.targets('backups'):
        directory = target_root / backup_id
        try:
            write_backup(directory, source, before, content_hash, metadata,
                         remote, pending=not remote and place.pending())
        except OSError as error:
            if not remote:
                raise
            place.failed(error)
            continue
        place.written[backup_id] = directory
        break
    print(f'BACKUP\t{name}\tside={side}\tid={backup_id}\treason={reason}')
    return backup_id


def backup_manifest(args, backup_id):
    return json.loads((args.backups.find(backup_id) / 'manifest.json').read_text(encoding='utf-8'))


def backup_leaves(root, kind):
    """Each backup is <id>/ under backups and <file key>/<versions>/ under conflict backups."""
    if not root.is_dir() or root.is_symlink():
        return []
    children = [item for item in root.iterdir() if item.is_dir() and not item.is_symlink()
                and '.partial-' not in item.name]
    if kind == 'backups':
        return sorted(children)
    return sorted(version for key in children for version in key.iterdir()
                  if version.is_dir() and not version.is_symlink()
                  and '.partial-' not in version.name)


def move_verified(source, target):
    """Copy one backup directory, verify every byte, and only then remove the source."""
    members = sorted(item for item in source.rglob('*')
                     if item.is_file() and not item.is_symlink() and item.name != PENDING_MOVE)
    manifest_path = source / 'manifest.json'
    tree_metadata = (json.loads(manifest_path.read_text(encoding='utf-8'))
                     if manifest_path.is_file() else {})
    if tree_metadata.get('kind') == 'tree':
        checked_tree_backup(source, tree_metadata)
        if target.exists():
            if json.loads((target / 'manifest.json').read_text(encoding='utf-8')) != tree_metadata:
                raise OSError('目标位置已有不同的同名目录备份')
            checked_tree_backup(target, tree_metadata)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            staging = target.with_name(target.name + '.partial-' + uuid.uuid4().hex)
            copy_tree_verified(source.parent, source.name, staging)
            checked_tree_backup(staging, tree_metadata)
            os.rename(staging, target)
        shutil.rmtree(source)
        return
    if target.exists():
        for item in members:
            existing = target / item.relative_to(source)
            if not existing.is_file() or digest(existing) != digest(item):
                raise OSError(f'目标位置已有内容不同的同名备份：{target}')
    else:
        staging = target.with_name(target.name + '.partial-' + uuid.uuid4().hex[:8])
        staging.mkdir(parents=True)
        try:
            for item in members:
                destination = staging / item.relative_to(source)
                destination.parent.mkdir(parents=True, exist_ok=True)
                copy_atomic(item, destination, signature(item), None)
                if digest(destination) != digest(item):
                    raise OSError(f'复制后校验失败：{destination}')
            manifest = staging / 'manifest.json'
            if manifest.is_file():
                expected = json.loads(manifest.read_text(encoding='utf-8')).get('sha256')
                if expected and digest(staging / 'content') != expected:
                    raise OSError('备份内容与清单校验值不一致')
            os.rename(staging, target)
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
    shutil.rmtree(source)


def move_backups(args, only_pending):
    """Move local backups to the chosen backup folder; return (moved, failed)."""
    place = args.backups
    if place.remote is None:
        raise ValueError('尚未设置本机以外的备份位置')
    if not place.available:
        if only_pending:
            return 0, 0
        raise OSError(f'备份位置当前不可用：{place.remote}')
    moved = failed = 0
    for kind in ('backups', 'conflict-backups'):
        local_root = place.local[kind]
        for directory in backup_leaves(local_root, kind):
            if only_pending and not (directory / PENDING_MOVE).exists():
                continue
            relative = directory.relative_to(local_root)
            try:
                move_verified(directory, place.remote / kind / relative)
                moved += 1
                print(f'MOVED_BACKUP\t{kind}/{relative.as_posix()}')
            except OSError as error:
                failed += 1
                print(f'BACKUP_PENDING\t{kind}/{relative.as_posix()}\t备份暂未移动，仍保留在本机：{error}')
            if kind == 'conflict-backups' and directory.parent.is_dir() and not any(directory.parent.iterdir()):
                directory.parent.rmdir()
    return moved, failed


def copy_protected(args, source, destination, source_sig, destination_sig,
                   name, destination_side, reason='overwrite'):
    source_hash = digest(source)
    destination_hash = digest(destination) if destination_sig is not None else None
    if signature(source) != source_sig or signature(destination) != destination_sig:
        raise OSError('文件在备份前发生变化，已跳过本次复制')
    if destination_sig is not None:
        backup_id = backup_file(args, args.local if destination_side == 'local' else args.cloud,
                                name, destination_side, reason, args.backup_retention_days)
        if backup_id:
            args.backup_count += 1
            if backup_manifest(args, backup_id)['sha256'] != destination_hash:
                raise OSError('目标文件在备份期间发生变化，已取消覆盖')
    if destination_side == 'local' and destination_sig is None and not hasattr(args, 'released_metadata'):
        args.released_metadata = cloud_only.released_file_metadata(args.local, args.state)
    copy_atomic(source, destination, source_sig, destination_sig,
                source_hash, destination_hash)
    if destination_side == 'local' and destination_sig is None:
        cloud_only.restore_file_metadata(args.local, name, source_hash, args.released_metadata)


def delete_protected(args, root, name, side):
    target = safe_path(root, name)
    before = signature(target)
    if before is None:
        return
    backup_id = backup_file(args, root, name, side, 'delete', args.backup_retention_days)
    if backup_id is None:
        raise OSError('删除前文件已改变，已取消删除')
    args.backup_count += 1
    backed_up_hash = backup_manifest(args, backup_id)['sha256']
    if signature(target) != before or digest(target) != backed_up_hash:
        raise OSError('删除前文件发生变化，已取消删除')
    target.unlink()
    print(f'DELETED\t{name}\tside={side}')


def prune_backups(args, retention_days):
    for root in args.backups.roots('backups'):
        prune_backup_root(root, retention_days)


def prune_backup_root(root, retention_days):
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
    directory = args.backups.find(backup_id)
    if directory is None:
        raise OSError('找不到这个备份；备份位置可能暂时不可用')
    metadata = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if metadata.get('id') != backup_id or metadata.get('side') not in ('local', 'cloud'):
        raise ValueError('备份信息无效')
    root = local if metadata['side'] == 'local' else cloud
    if metadata.get('root') != str(root):
        raise ValueError('备份对应的同步路径已变更')
    name = metadata['name']
    ensure_not_cloud_only(args, name)
    destination = safe_path(root, name)
    payload = directory / 'content'
    if metadata.get('kind') == 'tree':
        if any(cloud_only.overlaps(path, name) for path in args.cloud_only):
            raise ValueError('恢复目标包含仅云端路径，请先调整仅云端设置')
        checked_tree_backup(directory, metadata)
        install_tree(directory, 'content', root, name)
        print(f'RESTORED\t{name}\tside={metadata["side"]}\tfrom={backup_id}')
        return 0
    if payload.is_symlink() or digest(payload) != metadata['sha256']:
        raise OSError('备份内容校验失败，已取消恢复')
    existing = signature(destination)
    if existing is not None:
        backup_file(args, root, name, metadata['side'], 'restore-overwrite',
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


def backup_pair(args, name, local_file, cloud_file, local_sig, cloud_sig, hashes):
    key = hashlib.sha256(name.encode('utf-8')).hexdigest()[:16]
    version = hashes[0][:12] + '-' + hashes[1][:12]
    suffix = local_file.suffix
    place = args.backups
    for target_root, remote in place.targets('conflict-backups'):
        backup_dir = target_root / key / version
        local_backup = backup_dir / ('local' + suffix)
        cloud_backup = backup_dir / ('cloud' + suffix)
        try:
            backup_dir.mkdir(parents=True, exist_ok=True)
            backup_original(local_file, local_backup, hashes[0])
            backup_original(cloud_file, cloud_backup, hashes[1])
            if not remote and place.pending():
                (backup_dir / PENDING_MOVE).write_text('', encoding='utf-8')
        except OSError as error:
            if not remote:
                raise
            place.failed(error)
            continue
        break
    if checked_digests(local_file, cloud_file, local_sig, cloud_sig) != hashes:
        raise OSError('备份期间文件发生变化；请重新同步')
    return backup_dir, local_backup, cloud_backup


def preserve_both(args, local, cloud, name, local_sig, cloud_sig, hashes,
                  backups=None, primary='local'):
    state_path = args.state
    local_file = safe_path(local, name)
    cloud_file = safe_path(cloud, name)
    backup_dir, local_backup, cloud_backup = backups or backup_pair(
        args, name, local_file, cloud_file, local_sig, cloud_sig, hashes)
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
    if args.conflict_policy == 'keep-both':
        # Automatic keep-both needs no follow-up: both versions are already on
        # both sides and in the history, so no review stays pending.
        conflicts = {name: record for name, record in conflicts.items() if not is_review(record)}
    next_files = dict(files)
    next_conflicts = dict(conflicts)
    errors = []
    active_files = {name: record for name, record in files.items()
                    if not excluded_path(name, args)}
    active_conflicts = {name: record for name, record in conflicts.items()
                        if not excluded_path(name, args, directory=record.get('kind') == 'tree')}
    symlinks = set()
    local_names = scan(local, args, errors, symlinks)
    cloud_names = scan(cloud, args, errors, symlinks)
    index = getattr(args, 'graph_index', None)
    index_unverified = set()
    if index:
        for name, remote in index.entries.items():
            if excluded_path(name, args):
                continue
            try:
                mirror = signature(safe_path(cloud, name))
                valid = (mirror is not None and mirror[0] == remote['size']
                         and remote['mtime'] is not None
                         and abs(mirror[1] - remote['mtime']) < 1_000_000_000)
            except OSError:
                valid = False
            if not valid:
                index_unverified.add(name)
    # Preserve unverified paths and their ancestors; provider lag is never
    # evidence for deletion. Independent files can still make progress.
    index_unverified_parents = {directory for name in index_unverified
                                for directory in ancestor_directories(name)}
    names = local_names | cloud_names | set(active_files) | set(active_conflicts) | index_unverified
    counts = {'uploaded': 0, 'downloaded': 0, 'unchanged': 0,
              'kept_both': 0, 'newest': 0, 'deleted': 0, 'backups': 0,
              'skipped': 0, 'conflicts': 0, 'reviews': 0, 'failed': 0, 'online_only': 0}

    def aligned(path_name, local_sig, cloud_sig, content_hash):
        return {'local': local_sig, 'cloud': cloud_sig, 'anchorHash': content_hash,
                'localCtime': change_time(safe_path(local, path_name)),
                'cloudCtime': change_time(safe_path(cloud, path_name))}

    tree_record_names = {name for name, record in active_conflicts.items()
                         if record.get('kind') == 'tree'}
    # An unresolved tree conflict above a cloud-only child must remain blocked;
    # filtering that child is not evidence that the old conflict was resolved.
    protected_tree_conflicts = {
        name for name, record in active_conflicts.items()
        if record.get('kind') == 'tree' and
        any(cloud_only.contains(prefix, (name,)) for prefix in args.cloud_only)
    }
    blocked_directories = set(protected_tree_conflicts)
    plan = []

    def planned(action, name, **detail):
        # Only a preview reports individual planned actions; it never writes.
        if args.dry_run:
            plan.append({'action': action, 'name': name, **detail})

    def linked(name):
        return name in symlinks or any(parent in symlinks for parent in ancestor_directories(name))

    for name in sorted(protected_tree_conflicts):
        print(f'CONFLICT\t{name}\t云端保留子路径的上级目录仍有冲突，请先核对')
        planned('conflict', name, kind='tree')
        counts['conflicts'] += 1

    # Scanning skips links, but a peer file or an old anchor can reintroduce
    # the same path. Exclude it on BOTH sides before metadata checks, directory
    # deletion detection and prefetch. Keep the peer and anchor untouched so a
    # link conversion never looks like a deletion or follows an external target.
    for name in sorted(name for name in names if linked(name)):
        detail = '路径或上级目录是符号链接；保留两端文件及同步基线，不跟随链接'
        print(f'SKIPPED\t{name}\t{detail}')
        planned('skip', name, detail=detail)
        counts['skipped'] += 1
    names = {name for name in names if not linked(name)}
    local_names &= names
    cloud_names &= names
    active_files = {name: record for name, record in active_files.items() if not linked(name)}
    active_conflicts = {name: record for name, record in active_conflicts.items() if not linked(name)}
    tree_record_names = {name for name in tree_record_names if not linked(name)}

    def blocked(name):
        return any(name == directory or within_directory(name, directory)
                   for directory in blocked_directories)

    # A deletion of a parent and an edit below it is one tree conflict. Resolve
    # existing barriers first, then detect new ones before touching any child.
    for directory in sorted(tree_record_names, key=lambda item: (item.count('/'), item)):
        if blocked(directory):
            continue
        record = active_conflicts[directory]
        if directory in index_unverified_parents:
            blocked_directories.add(directory)
            print(f'FAILED\t{directory}\tOneDrive 目录含未核验的云端文件，保留目录冲突与基线')
            planned('failed', directory, detail='云端目录元数据尚未就绪')
            counts['failed'] += 1
            continue
        try:
            left = directory_snapshot(local, directory, args)
            right = directory_snapshot(cloud, directory, args)
            anchor_tree = anchor_directory_snapshot(directory, active_files)
            reverted_edit = ((left is None and right == anchor_tree
                              and record.get('deletedSide') == 'local') or
                             (right is None and left == anchor_tree
                              and record.get('deletedSide') == 'cloud'))
            if left == right or reverted_edit or (left is not None and right is not None):
                if not args.dry_run:
                    next_conflicts.pop(directory, None)
                continue
            if not args.dry_run:
                next_conflicts[directory] = {**record, 'localTree': serialized_tree(left),
                                             'cloudTree': serialized_tree(right)}
            blocked_directories.add(directory)
            print(f'CONFLICT\t{directory}\t目录删除与内部修改尚未解决，已暂停整个目录')
            planned('conflict', directory, kind='tree')
            counts['conflicts'] += 1
        except (OSError, ValueError) as error:
            blocked_directories.add(directory)
            print(f'FAILED\t{directory}\t无法核验目录冲突：{error}')
            planned('failed', directory, detail=str(error))
            counts['failed'] += 1

    anchored_directories = {directory for name, record in active_files.items()
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
            if directory in index_unverified_parents and not (left_exists and right_exists):
                blocked_directories.add(directory)
                print(f'FAILED\t{directory}\t目录内云端元数据未就绪，未确认目录删除')
                planned('failed', directory, detail='目录内云端元数据未就绪')
                counts['failed'] += 1
                continue
            if left_exists == right_exists:
                continue
            deleted_side = 'cloud' if left_exists else 'local'
            surviving_root = local if left_exists else cloud
            surviving = directory_snapshot(surviving_root, directory, args)
            if surviving == anchor_directory_snapshot(directory, active_files):
                continue
            blocked_directories.add(directory)
            tree_record_names.add(directory)
            if not args.dry_run:
                next_conflicts[directory] = {
                    'kind': 'tree', 'reason': 'directory_delete_edit',
                    'deletedSide': deleted_side,
                    'localTree': serialized_tree(surviving if left_exists else None),
                    'cloudTree': serialized_tree(None if left_exists else surviving),
                    'local': None, 'cloud': None,
                    'detectedAt': datetime.now(timezone.utc).isoformat()}
            print(f'CONFLICT\t{directory}\t目录删除与内部修改冲突，已暂停整个目录')
            planned('conflict', directory, kind='tree')
            counts['conflicts'] += 1
        except (OSError, ValueError) as error:
            blocked_directories.add(directory)
            print(f'FAILED\t{directory}\t无法核验目录状态：{error}')
            planned('failed', directory, detail=str(error))
            counts['failed'] += 1

    # New cloud-only files are independent of the existing anchor. Import the
    # small ones first so a slow video cannot hold up thousands of documents.
    new_cloud_only = {name for name in cloud_names - local_names
                      if name not in active_files and name not in active_conflicts
                      and name not in tree_record_names and not blocked(name)}

    def import_priority(name):
        try:
            return signature(cloud / name)[0], name
        except (OSError, TypeError):
            return float('inf'), name

    import_names = sorted(new_cloud_only, key=import_priority)

    repaired_metadata = {}

    def locally_verified_anchor(name):
        record = files.get(name)
        if not record or not record.get('anchorHash') or name in conflicts:
            return False
        local_file, cloud_file = local / name, cloud / name
        try:
            local_sig, cloud_sig = signature(local_file), signature(cloud_file)
            if not (unchanged_metadata(local_sig, record.get('local'))
                    and unchanged_metadata(cloud_sig, record.get('cloud'), cloud=True)):
                return False
            before_ctime = change_time(local_file)
            if (before_ctime == record.get('localCtime')
                    or repaired_metadata.get(name) == before_ctime):
                return True
            matched = (digest(safe_path(local, name)) == record['anchorHash']
                       and signature(local_file) == local_sig
                       and change_time(local_file) == before_ctime)
            if matched:
                repaired_metadata[name] = before_ctime
            return matched
        except OSError:
            return False

    def needs_cloud_content(name):
        record = files.get(name)
        local_file, cloud_file = local / name, cloud / name
        try:
            if record is None or name in conflicts:
                return True
            if locally_verified_anchor(name):
                return False
            return not (unchanged_metadata(signature(local_file), record.get('local'))
                        and unchanged_metadata(signature(cloud_file), record.get('cloud'), cloud=True)
                        and record.get('localCtime') == change_time(local_file))
        except OSError:
            return True

    online_only = []
    if args.hydrate_online_only and args.download_online_content and not args.dry_run:
        online_only = sorted((name for name in cloud_names
                              if name not in tree_record_names and not blocked(name)
                              and is_dataless(cloud / name) and needs_cloud_content(name)),
                             key=import_priority)
        if online_only:
            print(f'ONLINE_ONLY\t{len(online_only)}\t先从云端下载仅在线的文件')
        counts['online_only'] = len(online_only)
    # A preview never downloads placeholders; it reports them instead.
    ordered_names = sorted(names - new_cloud_only) + import_names
    prefetch = CloudPrefetch(cloud, [] if args.dry_run or not args.download_online_content else import_names, online_only,
                             order=ordered_names)
    total_names = len(names)
    print(f'PROGRESS\tPROCESS\t0\t{total_names}', flush=True)
    for processed, name in enumerate(ordered_names, 1):
        if processed % 128 == 0:
            print(f'PROGRESS\tPROCESS\t{processed}\t{total_names}', flush=True)
        if name in tree_record_names:
            continue
        if blocked(name):
            counts['skipped'] += 1
            continue
        if name in index_unverified:
            print(f'FAILED\t{name}\tOneDrive 本地目录尚未跟上服务器元数据；保留文件与基线')
            planned('failed', name, detail='OneDrive 镜像与服务器元数据尚未一致')
            counts['failed'] += 1
            continue
        prefetch_error = prefetch.check(name)
        if prefetch_error:
            print(f'FAILED\t{name}\t{prefetch_error}')
            planned('failed', name, detail=prefetch_error)
            counts['failed'] += 1
            continue
        try:
            relative = Path(name)
            if relative.is_absolute() or not relative.parts or '..' in relative.parts:
                raise ValueError(f'不安全的相对路径：{name}')
            # The common case only reads metadata. Validate every ancestor with
            # safe_path before any content read or write, not for a fast skip.
            local_file = local / relative
            cloud_file = cloud / relative
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

            if (args.dry_run and previous is None and name not in conflicts
                    and (local_sig is None) != (cloud_sig is None)):
                # A first copy has no anchor to compare with: its outcome does
                # not depend on the content, so a preview skips reading it.
                upload = local_sig is not None
                if (upload and args.direction == 'download') or (
                        not upload and args.direction == 'upload'):
                    counts['skipped'] += 1
                    continue
                detail = {'size': (local_sig if upload else cloud_sig)[0]}
                if not upload and is_dataless(cloud_file):
                    detail['online'] = True
                    counts['online_only'] += 1
                planned('upload' if upload else 'download', name, **detail)
                counts['uploaded' if upload else 'downloaded'] += 1
                continue

            if review and (local_sig is None or cloud_sig is None):
                raise OSError('待合并的主文件缺失；请先人工检查，未覆盖任何一侧')

            if index and not pending and not review and local_sig is not None and cloud_sig is not None:
                # Equality only; overwrites and deletion anchors retain SHA256 checks.
                sha = index.verified_common(name, safe_path(local, name), cloud_sig)
                if sha:
                    if signature(local_file) != local_sig or signature(cloud_file) != cloud_sig:
                        raise OSError('文件在云端哈希核验期间发生变化，请重试')
                    if not args.dry_run:
                        next_files[name] = aligned(name, local_sig, cloud_sig, sha)
                    counts['unchanged'] += 1
                    continue

            if (not args.dry_run and not pending and previous
                    and index is None and locally_verified_anchor(name)):
                if name in repaired_metadata:
                    next_files[name] = {**previous, 'localCtime': repaired_metadata[name]}
                counts['unchanged'] += 1
                continue

            if (index is None and not pending and previous and local_sig is not None and cloud_sig is not None
                    and unchanged_metadata(local_sig, previous.get('local'))
                    and unchanged_metadata(cloud_sig, previous.get('cloud'), cloud=True)
                    and previous.get('localCtime') == change_time(local_file)):
                if review:
                    local_file = safe_path(local, name)
                    cloud_file = safe_path(cloud, name)
                    review_hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
                    if review_hashes[0] != review_hashes[1]:
                        raise OSError('待合并的主文件两侧又出现不同版本；请先人工检查，未覆盖任何一侧')
                counts['unchanged'] += 1
                continue

            if args.dry_run and cloud_sig is not None and is_dataless(cloud_file):
                # Comparing needs the content, and a preview must not download it.
                planned('online', name, size=cloud_sig[0])
                counts['online_only'] += 1
                continue

            if not args.download_online_content and cloud_sig is not None and is_dataless(cloud_file):
                counts['online_only'] += 1
            print(f'PROGRESS\tFILE\t{name}', flush=True)
            local_file = safe_path(local, name)
            cloud_file = safe_path(cloud, name)

            if local_sig is not None and cloud_sig is not None:
                hashes = checked_digests(local_file, cloud_file, local_sig, cloud_sig)
            else:
                hashes = (digest(local_file) if local_sig is not None else None,
                          digest(cloud_file) if cloud_sig is not None else None)
                if signature(local_file) != local_sig or signature(cloud_file) != cloud_sig:
                    raise OSError('文件读取期间发生变化；请在编辑或编译结束后重试，本次未覆盖')
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
                        if args.conflict_policy == 'keep-both':
                            next_conflicts.pop(name, None)
                        else:
                            next_conflicts[name] = preserved_record(preserving, sidecar, primary)
                if not args.dry_run:
                    if previous is None:
                        if not hasattr(args, 'released_metadata'):
                            args.released_metadata = cloud_only.released_file_metadata(local, args.state)
                        cloud_only.restore_file_metadata(local, name, hashes[0], args.released_metadata)
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
                        planned('conflict', name, reason='same_mtime')
                        counts['conflicts'] += 1
                        continue
                    upload = local_sig[1] > cloud_sig[1]
                    if (upload and args.direction == 'download') or (
                            not upload and args.direction == 'upload'):
                        if not args.dry_run:
                            next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes,
                                                                    'newest_opposes_direction')
                        print(f'CONFLICT\t{name}\t较新版本与指定单向同步方向相反，未覆盖任何一侧')
                        planned('conflict', name, reason='newest_opposes_direction')
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
                        planned('newest', name, side='local' if upload else 'cloud')
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
                        next_conflicts.pop(name, None)
                        print(f'KEPT_BOTH\t{name}\tcopy={sidecar_name}\tbackup={backup_dir}')
                    else:
                        print(f'WOULD_KEEP_BOTH\t{name}')
                        planned('keep_both', name)
                    counts['kept_both'] += 1
                else:
                    reason = ('delete_edit' if local_sig is None or cloud_sig is None else
                              'pending' if pending else
                              'initial' if previous is None else 'both_changed')
                    if not args.dry_run:
                        next_conflicts[name] = conflict_record(local_sig, cloud_sig, hashes, reason)
                    print(f'CONFLICT\t{name}\t两侧内容不同，等待选择版本')
                    planned('conflict', name, reason=reason)
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
                    planned('delete', name, side='cloud' if upload else 'local')
                else:
                    planned('upload' if upload else 'download', name, size=source_sig[0])
            counts['deleted' if source_sig is None else 'uploaded' if upload else 'downloaded'] += 1
        except (OSError, ValueError) as error:
            print(f'FAILED\t{name}\t{error}')
            planned('failed', name, detail=str(error))
            counts['failed'] += 1

    prefetch.close()
    for path, error in errors:
        print(f'FAILED\t{path}\t{error}')
        planned('failed', path, detail=error)
        counts['failed'] += 1
    for name, record in sorted(next_conflicts.items()):
        if linked(name):
            continue
        if excluded_path(name, args, directory=record.get('kind') == 'tree'):
            continue
        if is_review(record):
            print(f'NEEDS_REVIEW\t{name}\tcopy={record["sidecar"]}')
            planned('review', name, copy=record['sidecar'])
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
        counts['conflicts'] = sum(not is_review(record) for name, record in next_conflicts.items()
                                  if not excluded_path(name, args,
                                                       directory=record.get('kind') == 'tree'))
        prune_backups(args, args.backup_retention_days)
    counts['backups'] = args.backup_count
    if args.plan_json:
        print('PLAN_JSON\t' + json.dumps({'direction': args.direction, 'items': plan,
                                          'counts': counts}, ensure_ascii=False))
    print(' '.join(f'{key}={value}' for key, value in counts.items()))
    return 2 if counts['conflicts'] or counts['failed'] else 0


def serialized_tree(snapshot):
    if snapshot is None:
        return None
    return {'files': snapshot['files'], 'dirs': sorted(snapshot['dirs'])}


def copy_tree_verified(source_root, relative, destination):
    """Copy a complete folder, including excluded entries and native metadata."""
    source = safe_path(source_root, relative)
    cloud_only.inventory(source_root, relative)
    if destination.exists() or destination.is_symlink():
        raise OSError('目录暂存目标已存在')
    if sys.platform == 'darwin':
        subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl',
                        str(source), str(destination)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    else:
        shutil.copytree(source, destination)
    return cloud_only.verify_copies(source_root, relative, destination.parent, destination.name)


def backup_tree(args, root, name, side):
    backup_id = uuid.uuid4().hex
    created = datetime.now(timezone.utc)
    for target_root, remote in args.backups.targets('backups'):
        directory = target_root / backup_id
        directory.mkdir(parents=True, exist_ok=False)
        try:
            verified = copy_tree_verified(root, name, directory / 'content')
            metadata = {'id': backup_id, 'name': name, 'side': side, 'reason': 'delete',
                        'kind': 'tree', 'root': str(root), 'createdAt': created.isoformat(),
                        'createdAtEpoch': created.timestamp(), 'retentionDays': args.backup_retention_days,
                        'treeEntries': {p: [entry['kind'], entry['size']]
                                        for p, entry in verified['inventory'].items()},
                        'treeHashes': verified['hashes'], 'treeMetadata': verified['metadata']}
            cloud_only.atomic_json(directory / 'manifest.json', metadata)
            if not remote and args.backups.pending():
                (directory / PENDING_MOVE).touch()
        except (OSError, subprocess.SubprocessError) as error:
            # Incomplete copies remain outside the data trees for inspection.
            if not remote:
                raise
            args.backups.failed(error)
            continue
        args.backups.written[backup_id] = directory
        args.backup_count += 1
        print(f'BACKUP\t{name}\tside={side}\tid={backup_id}\treason=delete')
        return directory, verified
    raise OSError('无法保存目录备份')


def checked_tree_backup(directory, metadata):
    entries = cloud_only.inventory(directory, 'content')
    if {p: [entry['kind'], entry['size']] for p, entry in entries.items()} != metadata['treeEntries']:
        raise OSError('目录备份结构已变化，已取消恢复')
    for name, entry in entries.items():
        path = 'content/' + name if name else 'content'
        if cloud_only.preserved_metadata(directory, path, entry) != metadata['treeMetadata'][name]:
            raise OSError('目录备份元数据已变化，已取消恢复')
        if entry['kind'] == 'file' and cloud_only.secure_digest(directory, path, entry) != metadata['treeHashes'][name]:
            raise OSError('目录备份内容校验失败，已取消恢复')


def install_tree(source_root, relative, root, name):
    destination = safe_path(root, name)
    if destination.exists() or destination.is_symlink():
        raise OSError('恢复目标已存在，请先刷新目录冲突')
    # Staging is on the destination filesystem. Rename must never replace a
    # folder created by another application while the copy was being verified.
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.pathsync-tree-', dir=root.parent))
    try:
        copy_tree_verified(source_root, relative, staging / 'payload')
        cloud_only.restore_target(staging, root, name)
    finally:
        if not (staging / 'payload').exists():
            staging.rmdir()


def resolve_tree_conflict(args, local, cloud, files, conflicts):
    name = args.resolve
    record = conflicts[name]
    if args.choice not in ('restore-tree', 'delete-tree'):
        raise ValueError('目录级冲突请选择恢复整个目录，或确认删除并备份')
    if any(cloud_only.overlaps(path, name) for path in args.cloud_only):
        raise ValueError('目录包含仅云端路径，请先调整仅云端设置')
    left = directory_snapshot(local, name, args)
    right = directory_snapshot(cloud, name, args)
    current = {'localTree': serialized_tree(left), 'cloudTree': serialized_tree(right)}
    if 'localTree' in record and any(current[key] != record.get(key) for key in current):
        raise OSError('目录在检测后发生变化，请重新预览或同步以刷新冲突，再选择处理方式')
    if (left is None) == (right is None):
        raise OSError('目录状态已变化，请重新预览或同步以刷新冲突')
    root, other, side = (cloud, local, 'cloud') if left is None else (local, cloud, 'local')
    # All members, including ignored files, are included in the recoverable copy.
    directory, verified = backup_tree(args, root, name, side)
    if args.choice == 'restore-tree':
        if directory_snapshot(root, name, args) != (right if left is None else left):
            raise OSError('备份后目录已变化，请刷新后重试')
        install_tree(directory, 'content', other, name)
        resulting = directory_snapshot(root, name, args)
        if resulting != directory_snapshot(other, name, args):
            raise OSError('恢复后目录又发生变化，已保留备份与冲突记录')
    else:
        source = safe_path(root, name)
        cloud_only.ensure_not_in_use(source)
        if cloud_only.inventory(root, name) != verified['inventory']:
            raise OSError('目录在备份后发生变化，已取消删除')
        staging = Path(tempfile.mkdtemp(prefix='.pathsync-tree-', dir=root.parent))
        try:
            cloud_only.stage_target(root, name, staging, verified['inventory'][''])
            try:
                cloud_only.ensure_not_in_use(staging / 'payload')
                cloud_only.verify_copies(staging, 'payload', directory, 'content', verified)
                if os.path.lexists(source):
                    raise OSError('原目录已被其他程序重新创建，保留备份及暂存目录')
                shutil.rmtree(staging / 'payload')
            except BaseException:
                # A failed cleanup may be partial. Restore from the complete
                # verified backup, never from a partially removed payload.
                if not os.path.lexists(source):
                    install_tree(directory, 'content', root, name)
                raise
        finally:
            if not (staging / 'payload').exists():
                staging.rmdir()
        resulting = None
    remaining_files = {p: entry for p, entry in files.items()
                       if p != name and not within_directory(p, name)}
    if resulting is not None:
        for path, content_hash in resulting['files'].items():
            remaining_files[path] = {'local': signature(safe_path(local, path)),
                                     'cloud': signature(safe_path(cloud, path)),
                                     'anchorHash': content_hash}
    remaining_conflicts = {p: entry for p, entry in conflicts.items()
                           if p != name and not within_directory(p, name)}
    save_state(args.state, local, cloud, remaining_files, remaining_conflicts)
    print(f'RESOLVED\t{name}\t{args.choice}\tbackup={directory}')
    return 0


def resolve_conflict(args, local, cloud, files, conflicts):
    name = args.resolve
    ensure_not_cloud_only(args, name)
    ensure_no_tree_barrier(name, conflicts)
    if name not in conflicts:
        raise ValueError(f'没有待处理冲突：{name}')
    record = conflicts[name]
    ensure_not_cloud_only(args, record.get('sidecar'))
    if record.get('kind') == 'tree':
        return resolve_tree_conflict(args, local, cloud, files, conflicts)
    if args.choice in ('restore-tree', 'delete-tree'):
        raise ValueError('该选项仅适用于目录冲突')
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

    backups = backup_pair(args, name, local_file, cloud_file,
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
    ensure_not_cloud_only(args, name)
    ensure_no_tree_barrier(name, conflicts)
    record = conflicts.get(name)
    if record is None or not is_review(record):
        raise ValueError(f'没有待确认的已保留版本：{name}')
    ensure_not_cloud_only(args, record.get('sidecar'))
    primary = record['primary']
    sidecar = record['sidecar']
    main_local = safe_path(local, name)
    main_cloud = safe_path(cloud, name)
    copy_local = safe_path(local, sidecar)
    copy_cloud = safe_path(cloud, sidecar)
    main_sigs = (signature(main_local), signature(main_cloud))
    copy_sigs = (signature(copy_local), signature(copy_cloud))
    if any(item is None for item in (*main_sigs, *copy_sigs)):
        raise OSError('主文件或保留副本缺失；请人工检查，未自动覆盖')
    main_hashes = checked_digests(main_local, main_cloud, *main_sigs)
    copy_hashes = checked_digests(copy_local, copy_cloud, *copy_sigs)
    if copy_hashes[0] != copy_hashes[1]:
        raise OSError('保留副本两侧已有不同内容；请先核对副本，未自动覆盖')
    if copy_sigs[0][1] != copy_sigs[1][1]:
        raise OSError('保留副本两侧的修改日期不同；请人工检查，未自动覆盖')
    main_paths = (main_local, main_cloud)
    copy_paths = (copy_local, copy_cloud)
    if main_hashes[0] == main_hashes[1]:
        if main_sigs[0][1] != main_sigs[1][1]:
            raise OSError('主文件两侧的修改日期不同；请人工检查，未自动覆盖')
        main_index = 0 if primary == 'local' else 1
    else:
        anchor = files.get(name, {}).get('anchorHash')
        if not isinstance(anchor, str):
            raise OSError('主文件两侧不同且缺少共同版本；请人工检查，未自动覆盖')
        if main_hashes[0] == anchor and main_hashes[1] != anchor:
            main_index = 1
        elif main_hashes[1] == anchor and main_hashes[0] != anchor:
            main_index = 0
        else:
            raise OSError('主文件两侧都相对共同版本发生变化；请人工检查，未自动覆盖')
    if main_sigs[main_index][1] == copy_sigs[0][1]:
        raise ValueError('当前主文件与保留副本的修改时间相同；请人工检查后选择')
    main_is_newer = main_sigs[main_index][1] > copy_sigs[0][1]
    if main_is_newer and main_hashes[0] != main_hashes[1]:
        stale_index = 1 - main_index
        copy_protected(args, main_paths[main_index], main_paths[stale_index],
                       main_sigs[main_index], main_sigs[stale_index], name,
                       'local' if stale_index == 0 else 'cloud', 'review-newest-overwrite')
    elif not main_is_newer:
        for index, side in enumerate(('local', 'cloud')):
            copy_protected(args, copy_paths[index], main_paths[index],
                           copy_sigs[index], main_sigs[index], name,
                           side, 'review-newest-overwrite')
    chosen_hash = main_hashes[main_index] if main_is_newer else copy_hashes[0]
    winner = ('local' if main_index == 0 else 'cloud') if main_is_newer else (
        'cloud' if primary == 'local' else 'local')
    final_main_sigs = (signature(main_local), signature(main_cloud))
    if (None in final_main_sigs
            or checked_digests(main_local, main_cloud, *final_main_sigs) != (chosen_hash, chosen_hash)
            or (signature(copy_local), signature(copy_cloud)) != copy_sigs
            or checked_digests(copy_local, copy_cloud, *copy_sigs) != copy_hashes):
        raise OSError('选定版本在处理期间发生变化；请重新检查，冲突记录仍保留')
    next_files = dict(files)
    next_files[name] = {'local': final_main_sigs[0], 'cloud': final_main_sigs[1],
                        'anchorHash': chosen_hash}
    next_conflicts = dict(conflicts)
    next_conflicts.pop(name)
    save_state(args.state, local, cloud, next_files, next_conflicts)
    print(f'REVIEW_NEWEST\t{name}\tside={winner}\tcopy={sidecar}')
    return 0


def acknowledge_review(args, local, cloud, files, conflicts):
    name = args.acknowledge
    ensure_not_cloud_only(args, name)
    ensure_no_tree_barrier(name, conflicts)
    record = conflicts.get(name)
    if record is None or not is_review(record):
        raise ValueError(f'没有待确认的已保留版本：{name}')
    ensure_not_cloud_only(args, record.get('sidecar'))
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


def ensure_not_cloud_only(args, name):
    if name is not None and cloud_only.contains(name, getattr(args, 'cloud_only', ())):
        raise ValueError('该路径仅保留在云端，请先取消云端保留策略再执行手动操作')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local', type=Path)
    parser.add_argument('cloud', type=Path)
    parser.add_argument('state', type=Path)
    parser.add_argument('--direction', choices=('merge', 'upload', 'download'), default='merge')
    parser.add_argument('--conflict-policy', choices=('keep-both', 'ask', 'newest'), default='keep-both')
    parser.add_argument('--backup-retention-days', type=int, default=15)
    parser.add_argument('--exclude-latex', action='store_true')
    parser.add_argument('--skip-codex', action='store_true')
    parser.add_argument('--skip-claude', action='store_true')
    parser.add_argument('--include-temp', action='store_true')
    parser.add_argument('--exclude', action='append', default=[], metavar='PATTERN',
                        help='custom exclusion rule; may be repeated')
    parser.add_argument('--shared-excludes', action='store_true',
                        help='use authoritative shared rules and skip retired root ignore files')
    parser.add_argument('--cloud-only', action='append', default=[], metavar='RELATIVE_PATH',
                        help='keep this subpath in the cloud on this Mac; never sync its working copy')
    parser.add_argument('--release-local', metavar='RELATIVE_PATH',
                        help='verify the cloud mirror then release an exactly configured local working copy')
    parser.add_argument('--retire-cloud-only', action='store_true',
                        help='retire selected local baselines only, without scanning or syncing data')
    parser.add_argument('--download-online-content', action='store_true',
                        help='explicitly allow reading and downloading cloud placeholders; default never materializes them')
    parser.add_argument('--hydrate-online-only', action='store_true',
                        help='download online-only cloud files the merge must read before comparing')
    parser.add_argument('--graph-auth-helper', type=Path)
    parser.add_argument('--onedrive-root', type=Path)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--plan-json', action='store_true',
                        help='with --dry-run, also print the planned actions as one JSON line')
    parser.add_argument('--resolve', metavar='RELATIVE_PATH')
    parser.add_argument('--acknowledge', metavar='RELATIVE_PATH')
    parser.add_argument('--review-newest', metavar='RELATIVE_PATH')
    parser.add_argument('--restore', metavar='BACKUP_ID')
    parser.add_argument('--choice', choices=('local', 'cloud', 'both', 'newest', 'restore-tree', 'delete-tree'))
    parser.add_argument('--backup-root', type=Path,
                        help='existing folder (iCloud Drive, OneDrive, ...) that holds backups')
    parser.add_argument('--backup-subpath', help='this pair\'s folder relative to --backup-root')
    parser.add_argument('--migrate-backups', action='store_true',
                        help='move existing local backups to --backup-root, verifying each copy')
    args = parser.parse_args()
    if (args.backup_root is None) != (args.backup_subpath is None):
        parser.error('--backup-root and --backup-subpath must be given together')
    if args.migrate_backups and (args.backup_root is None or args.resolve or args.acknowledge
                                 or args.review_newest or args.restore or args.dry_run):
        parser.error('--migrate-backups requires --backup-root and no other action')
    if args.plan_json and not args.dry_run:
        parser.error('--plan-json requires --dry-run')
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
    if args.release_local is not None and (args.dry_run or args.resolve or args.acknowledge
            or args.review_newest or args.restore or args.migrate_backups):
        parser.error('--release-local cannot be combined with other actions or dry-run')
    if args.retire_cloud_only and (not args.cloud_only or args.dry_run or args.resolve
            or args.acknowledge or args.review_newest or args.restore or args.migrate_backups
            or args.release_local is not None):
        parser.error('--retire-cloud-only requires paths and cannot be combined with other actions')
    if args.retire_cloud_only:
        # This action must also allow unpinning an unavailable root or a path
        # since replaced by a link. Match state roots lexically without probing
        # provider paths; no data will be scanned, followed or removed.
        local = Path(os.path.abspath(args.local))
        cloud = Path(os.path.abspath(args.cloud))
        args.cloud_only = cloud_only.validate_policy(args.cloud_only)
        files, conflicts = load_state(args.state, local, cloud)
        files, receipt = cloud_only.retire_anchors(args.state, local, cloud, files, conflicts,
                                                  args.cloud_only, save_state)
        print('RETIRED_CLOUD_ONLY\tpaths=' + str(len(args.cloud_only)) +
              '\treceipt=' + (str(receipt) if receipt else 'none'))
        return 0
    global ALLOW_ONLINE_DOWNLOADS
    ALLOW_ONLINE_DOWNLOADS = args.download_online_content and not args.dry_run
    enable_cloud_materialization(ALLOW_ONLINE_DOWNLOADS)
    local = args.local.resolve()
    cloud = args.cloud.resolve()
    args.cloud_only = cloud_only.validate_paths(local, cloud, args.cloud_only)
    args.local, args.cloud = local, cloud
    args.backup_count = 0
    cloud_ignore = cloud / IGNORE_FILE
    if not args.shared_excludes and is_dataless(cloud_ignore):
        if args.dry_run or not args.download_online_content:
            raise OSError(f'{cloud_ignore}: 规则文件仅在线，请先下载后再同步或预览')
        error = CloudPrefetch.hydrate(cloud_ignore)
        if error:
            raise OSError(f'{cloud_ignore}: {error}')
    args.exclude_rules = (ExcludeRules(args.exclude) if args.shared_excludes
                          else load_exclude_rules(local, args.exclude, (cloud,)))
    args.backups = BackupPlace(args)
    if args.migrate_backups:
        moved, failed = move_backups(args, only_pending=False)
        print(f'backups_moved={moved} backups_pending={failed}')
        return 2 if failed else 0
    files, conflicts = load_state(args.state, local, cloud)
    if args.release_local is not None:
        rebuildable = tuple(rule[:-1] for rule in args.exclude
                            if rule.endswith('/') and rule[:-1] in cloud_only.REBUILDABLE_DIRECTORIES
                            and args.shared_excludes)
        return cloud_only.release_local(local, cloud, args.state, files, conflicts,
                                        args.release_local, args.cloud_only, save_state,
                                        rebuildable=rebuildable)
    for name in (args.resolve, args.review_newest, args.acknowledge):
        if name is not None:
            ensure_not_cloud_only(args, name)
            ensure_not_cloud_only(args, conflicts.get(name, {}).get('sidecar'))
    if args.cloud_only and not (args.dry_run or args.resolve or args.acknowledge
                               or args.review_newest or args.restore):
        files, _ = cloud_only.retire_anchors(args.state, local, cloud, files, conflicts,
                                           args.cloud_only, save_state)
    if not (args.dry_run or args.restore):
        # Backups kept here while the chosen folder was offline move there now.
        moved, _ = move_backups(args, only_pending=True) if args.backups.remote else (0, 0)
        if moved:
            print(f'BACKUPS_MOVED\t{moved}')
    if args.restore:
        return restore_backup(args, local, cloud)
    if args.review_newest:
        return resolve_review_newest(args, local, cloud, files, conflicts)
    if args.resolve:
        return resolve_conflict(args, local, cloud, files, conflicts)
    if args.acknowledge:
        return acknowledge_review(args, local, cloud, files, conflicts)
    args.graph_index = None
    if not args.graph_auth_helper:
        return sync_files(args, local, cloud, files, conflicts)
    if not args.onedrive_root:
        raise ValueError('云端索引需要 OneDrive 根目录')
    remote = cloud.relative_to(args.onedrive_root.resolve()).as_posix()
    auth = graph_index.credentials(args.graph_auth_helper)
    def progress(*fields):
        print('PROGRESS\tGRAPH\t' + '\t'.join(fields), flush=True)
    client = graph_index.GraphClient(auth['access_token'], progress)
    index = None
    try:
        index = graph_index.GraphIndex(args.state.with_suffix('.index.sqlite'), local, cloud,
                                      auth['drive_id'], remote, client.get, progress)
        index.refresh()
        args.graph_index = index
        result = sync_files(args, local, cloud, files, conflicts)
        index.flush_hashes()
        print('GRAPH_INDEX\t' + json.dumps({**index.stats, 'requests': client.requests,
              'wire_bytes': client.wire_bytes}, ensure_ascii=False))
        return result
    finally:
        if index:
            index.close()
        client.close()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f'FAILED\t{error}', file=sys.stderr)
        sys.exit(2)
