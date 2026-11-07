"""Per-machine cloud-only paths and verified local working-copy release.

These paths are deliberately independent of the shared exclusion document.
The provider's local mirror is the byte source for verification; this module
cannot certify whether the provider has completed a remote upload.
"""
import hashlib
import base64
import ctypes
import errno
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
import uuid

READ_TIMEOUT_SECONDS = 60
class UnstableFileError(OSError):
    """A bounded retry must start a fresh snapshot before any source move."""


REBUILDABLE_DIRECTORIES = {'.venv', '.tox', '.nox', '__pycache__', '.pytest_cache',
                           '.mypy_cache', '.ruff_cache', 'node_modules'}


def disposable_cache(name, kind, rebuildable, whole_tree=False):
    parts = Path(name).parts
    return (whole_tree or any(part in rebuildable for part in parts[:-1])
            or bool(parts and parts[-1] in rebuildable and kind in ('directory', 'symlink')))



def validate_relative(value):
    if (not isinstance(value, str) or not value or '\0' in value or '\\' in value
            or any(unicodedata.category(c) in ('Cc', 'Cf', 'Zl', 'Zp') for c in value)
            or value.startswith('/') or '//' in value or any(c in '*?[]{}' for c in value)):
        raise ValueError(f'云端保留路径必须是非空的组内相对路径：{value!r}')
    value = unicodedata.normalize('NFC', value)
    if value.endswith('/'):
        value = value[:-1]
    if (not value or len(value.encode('utf-8')) > 4096
            or any(p in ('', '.', '..') for p in value.split('/'))):
        raise ValueError('云端保留路径不能包含空分段、.、..，也不能超过4096字节')
    return value


def contains(name, prefixes):
    name = unicodedata.normalize('NFC', name)
    return any(name == unicodedata.normalize('NFC', prefix) or
               name.startswith(unicodedata.normalize('NFC', prefix) + '/') for prefix in prefixes)


def overlaps(name, prefix):
    name, prefix = unicodedata.normalize('NFC', name), unicodedata.normalize('NFC', prefix)
    return contains(name, (prefix,)) or prefix.startswith(name + '/')


def safe_target(root, relative):
    validate_relative(relative)
    path = Path(root)
    for component in relative.split('/'):
        path /= component
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise OSError(f'云端保留路径包含符号链接：{path}')
    return path


def validate_policy(values):
    values = tuple(sorted(set(validate_relative(value) for value in values)))
    return values


def validate_paths(local, cloud, values):
    values = validate_policy(values)
    for value in values:
        if any(value != other and contains(value, (other,)) for other in values):
            raise ValueError('云端保留子路径不能相互嵌套，请仅选择父路径或子路径')
    for value in values:
        safe_target(local, value)
        safe_target(cloud, value)
    return values


def atomic_json(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                         prefix=path.name + '.', delete=False) as f:
            temporary = Path(f.name)
            json.dump(document, f, ensure_ascii=False, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def retire_anchors(state, local, cloud, files, conflicts, prefixes, save_state):
    removed = {name: value for name, value in files.items() if contains(name, prefixes)}
    if not removed:
        return files, None
    history = Path(state).parent / (Path(state).name + '.cloud-only-history')
    history.mkdir(mode=0o700, exist_ok=True)
    receipt = history / (str(time.time_ns()) + '-' + uuid.uuid4().hex + '.json')
    atomic_json(receipt, {'version': 1, 'local': str(local), 'cloud': str(cloud),
                         'prefixes': list(prefixes), 'files': removed,
                         'reason': 'cloud-only baseline retired before intentional local absence'})
    remaining = {name: value for name, value in files.items() if name not in removed}
    save_state(state, local, cloud, remaining, conflicts)
    fsync_directory(Path(state).parent)
    return remaining, receipt


def _record(info, allow_symlinks=False):
    if stat.S_ISREG(info.st_mode):
        kind = 'file'
    elif stat.S_ISDIR(info.st_mode):
        kind = 'directory'
    elif allow_symlinks and stat.S_ISLNK(info.st_mode):
        kind = 'symlink'
    else:
        raise OSError('释放目标包含符号链接或特殊文件')
    # ctime can legitimately change when the whole target is renamed to staging.
    return {'kind': kind, 'size': info.st_size if kind in ('file', 'symlink') else 0,
            'identity': [info.st_dev, info.st_ino], 'mtime_ns': info.st_mtime_ns,
            'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}


def inventory(root, relative, allow_hardlinks=False, rebuildable=(), whole_tree=False):
    target = safe_target(root, relative)
    result = {}
    device = target.lstat().st_dev
    pending = [(target, '')]
    while pending:
        path, name = pending.pop()
        info = path.lstat()
        if info.st_dev != device:
            raise OSError('释放目标包含其他挂载点，无法安全核查占用')
        kind = ('directory' if stat.S_ISDIR(info.st_mode) else
                'symlink' if stat.S_ISLNK(info.st_mode) else 'file')
        discardable = disposable_cache(name, kind, rebuildable, whole_tree)
        record = _record(info, allow_symlinks=discardable)
        if record['kind'] == 'file' and not allow_hardlinks and not discardable and info.st_nlink != 1:
            raise OSError('本地副本含硬链接，无法隔离外部写入，保留本地文件')
        result[name] = record
        if record['kind'] == 'directory':
            if not info.st_mode & 0o444 or not info.st_mode & 0o111:
                raise PermissionError(f'目录不可读：{path}')
            with os.scandir(path) as entries:
                for entry in entries:
                    child = name + '/' + entry.name if name else entry.name
                    pending.append((Path(entry.path), child))
    return result


def _parent_fd(root, relative):
    parts = validate_relative(relative).split('/')
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in parts[:-1]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                              dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd, parts[-1]
    except BaseException:
        os.close(fd)
        raise


def _open_regular(root, relative):
    """Open every ancestor without following links, including after a race."""
    fd, leaf = _parent_fd(root, relative)
    try:
        return os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    finally:
        os.close(fd)


def stage_target(local, relative, staging, expected):
    source, leaf = _parent_fd(local, relative)
    destination = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if _record(os.stat(leaf, dir_fd=source, follow_symlinks=False)) != expected:
            raise OSError('释放移动前本地目标已变化')
        os.rename(leaf, 'payload', src_dir_fd=source, dst_dir_fd=destination)
        os.fsync(source)
        os.fsync(destination)
    finally:
        os.close(source)
        os.close(destination)


def restore_target(staging, local, relative):
    """Rollback without following links or replacing a newly created file."""
    source = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    destination, leaf = _parent_fd(local, relative)
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if hasattr(libc, 'renameatx_np'):
            rename = libc.renameatx_np
            flag = 0x00000004  # Darwin RENAME_EXCL
        elif hasattr(libc, 'renameat2'):
            rename = libc.renameat2
            flag = 1  # Linux RENAME_NOREPLACE
        else:
            raise OSError('系统缺少安全回滚的原子不覆盖移动；副本保留在 ' + str(staging))
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                           ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(source, b'payload', destination, os.fsencode(leaf), flag) != 0:
            error = ctypes.get_errno()
            raise OSError(error, '回滚未覆盖新建目标；完整暂存副本保留在 ' + str(staging))
        os.fsync(source)
        os.fsync(destination)
    finally:
        os.close(source)
        os.close(destination)


def secure_digest(root, relative, expected, provider_retries=0):
    previous_alarm = signal.getsignal(signal.SIGALRM)
    def deadline(_signal, _frame):
        raise TimeoutError(f'释放核验读取超时：{relative}')
    signal.signal(signal.SIGALRM, deadline)
    signal.setitimer(signal.ITIMER_REAL, READ_TIMEOUT_SECONDS)
    try:
        fd = _open_regular(root, relative)
        with os.fdopen(fd, 'rb') as f:
            before = os.fstat(f.fileno())
            if not before.st_mode & 0o444:
                raise PermissionError(f'释放核验文件不可读：{relative}')
            if _record(before) != expected or expected['kind'] != 'file':
                raise UnstableFileError(f'释放核验前文件已变化：{relative}')
            digest = hashlib.sha256()
            count = 0
            for block in iter(lambda: f.read(1024 * 1024), b''):
                count += len(block)
                digest.update(block)
            after = os.fstat(f.fileno())
            if _record(after) != expected or count != expected['size']:
                raise UnstableFileError(f'释放核验时文件已变化：{relative}')
            if before.st_ctime_ns != after.st_ctime_ns:
                if provider_retries:
                    return secure_digest(root, relative, expected, provider_retries - 1)
                raise UnstableFileError(f'释放核验时文件已变化：{relative}')
            return digest.hexdigest()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_alarm)


def preserved_metadata(root, relative, expected):
    fd = _open_regular(root, relative)
    try:
        if _record(os.fstat(fd)) != expected:
            raise UnstableFileError('释放元数据核验期间目标已变化')
        libc = ctypes.CDLL(None, use_errno=True)
        list_attrs = libc.flistxattr
        get_attr = libc.fgetxattr
        list_attrs.restype = get_attr.restype = ctypes.c_ssize_t
        list_args = (fd, None, 0, 0) if sys.platform == 'darwin' else (fd, None, 0)
        length = list_attrs(*list_args)
        if length < 0:
            error = ctypes.get_errno()
            if error not in (errno.ENOTSUP,):
                raise OSError(error, '无法完整读取文件扩展属性')
            length = 0
        if length > 65536:
            raise OSError('文件扩展属性列表过大，保留本地副本')
        buffer = ctypes.create_string_buffer(length)
        args = (fd, buffer, length, 0) if sys.platform == 'darwin' else (fd, buffer, length)
        if length and list_attrs(*args) != length:
            raise OSError('读取时文件扩展属性列表已变化')
        attrs = {}
        for raw_name in buffer.raw.split(b'\0'):
            if not raw_name:
                continue
            name = os.fsdecode(raw_name)
            # These describe storage/provider representation, not user forks,
            # tags, ACLs, encoding, quarantine or application metadata.
            if (name == 'com.apple.decmpfs' or name.startswith('com.apple.fileprovider.')
                    or name.startswith('com.microsoft.OneDrive')):
                continue
            args = (fd, raw_name, None, 0, 0, 0) if sys.platform == 'darwin' else (fd, raw_name, None, 0)
            size = get_attr(*args)
            if size < 0 or size > 1024 * 1024:
                raise OSError('扩展属性不可读或过大，保留本地副本：' + name)
            value = ctypes.create_string_buffer(size)
            args = (fd, raw_name, value, size, 0, 0) if sys.platform == 'darwin' else (fd, raw_name, value, size)
            if get_attr(*args) != size:
                raise OSError('扩展属性读取时发生变化：' + name)
            attrs[name] = {'bytes': size, 'sha256': hashlib.sha256(value.raw).hexdigest()}
            if name == 'com.apple.quarantine':
                attrs[name]['value'] = base64.b64encode(value.raw).decode('ascii')
        if sys.platform == 'darwin':
            libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
            libc.acl_get_fd_np.restype = ctypes.c_void_p
            libc.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
            libc.acl_to_text.restype = ctypes.c_void_p
            libc.acl_free.argtypes = [ctypes.c_void_p]
            acl = libc.acl_get_fd_np(fd, 0x100)
            if not acl:
                if ctypes.get_errno() not in (errno.ENOENT, errno.ENOTSUP):
                    raise OSError('无法完整读取文件ACL，保留本地副本')
            else:
                text = None
                try:
                    size = ctypes.c_ssize_t()
                    text = libc.acl_to_text(acl, ctypes.byref(size))
                    if not text:
                        raise OSError('无法完整读取文件ACL，保留本地副本')
                    raw = ctypes.string_at(text, size.value)
                    attrs['@acl'] = {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                finally:
                    if text:
                        libc.acl_free(text)
                    libc.acl_free(acl)
        return {'mode': expected['mode'], 'uid': expected['uid'], 'gid': expected['gid'], 'attributes': attrs}
    finally:
        os.close(fd)


def ensure_not_in_use(payload):
    executable = '/usr/sbin/lsof' if sys.platform == 'darwin' else shutil.which('lsof')
    if not executable or not Path(executable).is_file():
        raise OSError('缺少文件占用核查工具，保留本地副本')
    command = [str(executable), '-nP', '-F0pcfan']
    command += ['+D', str(payload)] if payload.is_dir() else ['--', str(payload)]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise OSError('无法完成文件占用核查，保留本地副本') from error
    # +D may return 1 even with matching FD/mmap records. Any output is busy;
    # do not discard txt/mem, read-only or directory handles.
    if result.stdout:
        raise OSError('本地副本仍被应用打开或映射，请关闭占用程序后重试')
    if result.stderr or result.returncode != 1:
        raise OSError('文件占用核查不完整，保留本地副本')


def _joined(prefix, name):
    return prefix + '/' + name if name else prefix


def mirror_metadata(metadata, directory):
    # File Provider stores per-device access/last-use records. Directory group
    # and other permissions may be narrowed to 0700 in its private mirror.
    attributes = {key: value for key, value in metadata['attributes'].items()
                  if key not in ('com.apple.macl', 'com.apple.lastuseddate#PS')}
    return {**metadata, 'mode': metadata['mode'] & ~0o077 if directory else metadata['mode'],
            'attributes': attributes}


def metadata_retained(left, right, directory, provider_mirror):
    if not provider_mirror:
        return left == right
    source = mirror_metadata(left, directory)
    retained = mirror_metadata(right, directory)
    retained['attributes'] = {key: value for key, value in retained['attributes'].items()
                              if key in source['attributes']}
    # Exact source permissions and quarantine provenance are archived before
    # release and restored when the same content is downloaded back to local.
    if (source['mode'] & 0o700) & ~(retained['mode'] & 0o700) == 0:
        retained['mode'] = source['mode']
    quarantine = source['attributes'].get('com.apple.quarantine')
    if quarantine and 'value' in quarantine and retained['attributes'].get('com.apple.quarantine'):
        source['attributes'].pop('com.apple.quarantine')
        retained['attributes'].pop('com.apple.quarantine')
    return source == retained


def write_quarantine(fd, value, create_only=False):
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        flags = 0x2 if create_only else 0  # XATTR_CREATE never replaces another origin.
        arguments = (fd, b'com.apple.quarantine', value, len(value), 0, flags)
    else:
        arguments = (fd, b'com.apple.quarantine', value, len(value), 1 if create_only else 0)
    if libc.fsetxattr(*arguments) != 0:
        raise OSError(ctypes.get_errno(), '无法保存文件来源记录')


def verify_copies(local, relative, cloud, cloud_relative=None, expected=None,
                  provider_mirror=False, rebuildable=(), repair_metadata=False):
    cloud_relative = cloud_relative or relative
    rebuildable = tuple(sorted(set(rebuildable) & REBUILDABLE_DIRECTORIES)) if provider_mirror else ()
    whole_tree = expected.get('whole_tree', False) if expected else Path(relative).name in rebuildable
    source = inventory(local, relative, rebuildable=rebuildable, whole_tree=whole_tree)
    remote = inventory(cloud, cloud_relative, allow_hardlinks=True,
                       rebuildable=rebuildable, whole_tree=whole_tree)
    if expected is not None and source != expected['inventory']:
        raise OSError('释放暂存后的本地目录发生变化，已拒绝清理')
    hashes = {}
    metadata = {}
    remote_metadata = {}
    discarded = {name for name, entry in source.items()
                 if disposable_cache(name, entry['kind'], rebuildable, whole_tree)}
    file_count = sum(entry['kind'] == 'file' for name, entry in source.items() if name not in discarded)
    last_progress = time.monotonic()
    print(f'PROGRESS\tRELEASE_VERIFY\t0\t{file_count}', flush=True)
    for name, entry in source.items():
        if name in discarded:
            metadata[name] = remote_metadata[name] = None
            continue
        other = remote.get(name)
        disposable = (provider_mirror and other is None and entry['kind'] == 'file'
                      and Path(name or relative).name == '.DS_Store')
        if not disposable and (other is None or (entry['kind'], entry['size']) != (other['kind'], other['size'])):
            raise OSError(f'云端副本缺少文件或类型/大小不同：{name or relative}')
        left_metadata = preserved_metadata(local, _joined(relative, name), entry)
        right_metadata = None if disposable else preserved_metadata(cloud, _joined(cloud_relative, name), other)
        if expected is not None and left_metadata != expected['metadata'][name]:
            raise OSError(f'本地文件元数据已变化：{name or relative}')
        if entry['kind'] == 'file':
            left = secure_digest(local, _joined(relative, name), entry)
            right = left if disposable else secure_digest(cloud, _joined(cloud_relative, name), other,
                                                           provider_retries=2 if provider_mirror else 0)
            if left != right or (expected is not None and left != expected['hashes'][name]):
                raise OSError(f'云端副本内容不同或本地文件已变化：{name or relative}')
            hashes[name] = left
            if len(hashes) == file_count or time.monotonic() - last_progress >= 5:
                print(f'PROGRESS\tRELEASE_VERIFY\t{len(hashes)}\t{file_count}', flush=True)
                last_progress = time.monotonic()
        origin = left_metadata['attributes'].get('com.apple.quarantine', {}).get('value')
        if (repair_metadata and provider_mirror and not disposable and origin is not None
                and 'com.apple.quarantine' not in right_metadata['attributes']):
            path = _joined(cloud_relative, name)
            fd = _open_regular(cloud, path)
            try:
                if _record(os.fstat(fd)) != other:
                    raise UnstableFileError('补齐来源记录前云端文件已变化')
                try:
                    write_quarantine(fd, base64.b64decode(origin, validate=True), create_only=True)
                except OSError as error:
                    if error.errno != errno.EEXIST:
                        raise
            finally:
                os.close(fd)
            right_metadata = preserved_metadata(cloud, path, other)
        if not disposable and not metadata_retained(left_metadata, right_metadata,
                                                     entry['kind'] == 'directory', provider_mirror):
            raise OSError(f'云端副本权限、资源分叉或扩展属性不同：{name or relative}')
        metadata[name] = left_metadata
        remote_metadata[name] = right_metadata
    if inventory(local, relative, rebuildable=rebuildable, whole_tree=whole_tree) != source:
        raise UnstableFileError('释放核验期间本地目录发生变化')
    # Reject disappearing/changing corresponding cloud entries, including links.
    final_remote = inventory(cloud, cloud_relative, allow_hardlinks=True,
                             rebuildable=rebuildable, whole_tree=whole_tree)
    if any(final_remote.get(name) != remote.get(name) for name in source if name not in discarded):
        raise UnstableFileError('释放核验期间云端镜像发生变化')
    for name, entry in source.items():
        if name in discarded:
            continue
        if preserved_metadata(local, _joined(relative, name), entry) != metadata[name]:
            raise UnstableFileError('释放核验期间本地扩展属性或权限发生变化')
        if remote_metadata[name] is not None:
            final_metadata = preserved_metadata(cloud, _joined(cloud_relative, name), remote[name])
            if not metadata_retained(metadata[name], final_metadata, entry['kind'] == 'directory', provider_mirror):
                raise UnstableFileError('释放核验期间云端扩展属性或权限发生变化')
    return {'inventory': source, 'hashes': hashes, 'metadata': metadata,
            'rebuildable': rebuildable, 'whole_tree': whole_tree, 'discarded': sorted(discarded)}


def released_file_metadata(local, state):
    result = {}
    index = Path(state).parent / (Path(state).name + '.cloud-only-releases')
    if not index.is_dir():
        return result
    for pointer in sorted(index.glob('*.json'), key=lambda path: path.stat().st_mtime_ns):
        receipt = json.loads(pointer.read_text(encoding='utf-8'))
        if receipt.get('status') != 'released' or receipt.get('state') != str(state):
            continue
        relative = validate_relative(receipt['relative'])
        if receipt.get('target') != str(safe_target(local, relative)):
            continue
        journal = json.loads(Path(receipt['journal']).read_text(encoding='utf-8'))
        verification = journal['verification']
        for name, content_hash in verification['hashes'].items():
            metadata = verification['metadata'][name]
            if metadata is not None:
                result[_joined(relative, name)] = (content_hash, metadata)
    return result


def restore_file_metadata(local, relative, content_hash, archived):
    record = archived.get(relative)
    if record is None or record[0] != content_hash:
        return
    metadata = record[1]
    fd = _open_regular(local, relative)
    try:
        if os.fstat(fd).st_uid != metadata['uid']:
            raise OSError('恢复文件的所有者已变化，原始元数据仍保留在释放记录中')
        current = _record(os.fstat(fd))
        if secure_digest(local, relative, current) != content_hash:
            raise OSError('恢复元数据前文件已变化，保留当前文件及原始元数据记录')
        quarantine = metadata['attributes'].get('com.apple.quarantine', {}).get('value')
        if quarantine is not None:
            value = base64.b64decode(quarantine, validate=True)
            write_quarantine(fd, value)
        os.fchmod(fd, metadata['mode'])
    finally:
        os.close(fd)


def _working_copy_root(local, cloud):
    local, cloud = Path(local).resolve(), Path(cloud).resolve()
    if local == cloud or local in cloud.parents or cloud in local.parents:
        raise ValueError('释放本地目录不能与云端镜像重叠')
    parts = local.parts
    if ('CloudStorage' in parts or
            any(parts[i:i + 2] == ('Library', 'Mobile Documents') for i in range(len(parts) - 1))):
        raise ValueError('不能释放或删除云盘提供程序镜像，只能释放本地工作副本')
    return local, cloud


def _related_conflicts(relative, conflicts):
    return [name for name, record in conflicts.items()
            if overlaps(name, relative) or
            (isinstance(record.get('sidecar'), str) and overlaps(record['sidecar'], relative))]


def _save_receipt(journal, state, receipt):
    atomic_json(journal, receipt)
    # Keep a stable recovery pointer beside sync state even if the helper is
    # interrupted after renaming and before its final stdout reaches the UI.
    index = Path(state).parent / (Path(state).name + '.cloud-only-releases')
    index.mkdir(mode=0o700, exist_ok=True)
    recovery = {key: value for key, value in receipt.items() if key != 'verification'}
    recovery['journal'] = str(journal)
    atomic_json(index / (journal.parent.name + '.json'), recovery)


def release_local(local, cloud, state, files, conflicts, relative, configured, save_state, rebuildable=()):
    relative = validate_relative(relative)
    if relative not in configured:
        raise ValueError('只能释放已精确配置为云端保留的子路径')
    local, cloud = _working_copy_root(local, cloud)
    if _related_conflicts(relative, conflicts):
        raise ValueError('释放目标存在未决冲突或上级目录冲突，请先处理')
    target = safe_target(local, relative)
    safe_target(cloud, relative)
    # All validation failures before staging leave state and both data trees untouched.
    original_state = Path(state).read_bytes() if Path(state).exists() else None
    for attempt in range(3):
        try:
            verified = verify_copies(local, relative, cloud, provider_mirror=True, rebuildable=rebuildable, repair_metadata=True)
            break
        except UnstableFileError:
            if attempt == 2:
                raise
            time.sleep(1)
    if (Path(state).read_bytes() if Path(state).exists() else None) != original_state:
        raise OSError('核验期间同步状态已变化，请重试；没有释放本地副本')
    staging = Path(tempfile.mkdtemp(prefix='.pathsync-local-release-', dir=local.parent))
    payload = staging / 'payload'
    journal = staging / 'release.json'
    receipt = {'version': 1, 'target': str(target), 'cloud': str(cloud / relative),
               'state': str(state), 'relative': relative, 'verification': verified,
               'status': 'verified', 'provider_remote_upload_confirmed': False}
    try:
        if target.lstat().st_dev != staging.lstat().st_dev:
            raise OSError('本地副本与暂存目录不在同一文件系统，拒绝释放')
        _save_receipt(journal, state, receipt)
        print('RELEASE_STAGING\t' + relative + '\treceipt=' + str(journal), flush=True)
        _, history = retire_anchors(state, local, cloud, files, conflicts, (relative,), save_state)
        receipt['baseline_snapshot'] = str(history) if history else None
        receipt['status'] = 'baseline_retired'
        _save_receipt(journal, state, receipt)
        # Refuse source changes between the complete verification and rename.
        if inventory(local, relative, rebuildable=verified['rebuildable'],
                     whole_tree=verified['whole_tree']) != verified['inventory']:
            raise OSError('释放前本地副本发生变化，没有移动文件')
        stage_target(local, relative, staging, verified['inventory'][''])
        receipt['status'] = 'staged'
        _save_receipt(journal, state, receipt)
        try:
            ensure_not_in_use(payload)
            verify_copies(staging, 'payload', cloud, relative, verified, provider_mirror=True, rebuildable=rebuildable, repair_metadata=True)
        except BaseException:
            if not os.path.lexists(target):
                restore_target(staging, local, relative)
                receipt['status'] = 'rolled_back'
                _save_receipt(journal, state, receipt)
            raise
        receipt['status'] = 'cleanup'
        _save_receipt(journal, state, receipt)
        if os.path.lexists(target):
            raise OSError(f'原工作路径已被其他程序重新创建；新文件未改动，完整暂存副本保留在 {staging}')
        # The namespace is private and the original path is absent. Recheck all
        # retained FD/mmap/directory references and bytes immediately before
        # destruction, after the last journal write and any external changes.
        ensure_not_in_use(payload)
        verify_copies(staging, 'payload', cloud, relative, verified, provider_mirror=True, rebuildable=rebuildable, repair_metadata=True)
        try:
            if payload.is_dir():
                shutil.rmtree(payload)
            else:
                payload.unlink()
        except OSError as error:
            receipt['status'] = 'cleanup_incomplete'
            receipt['error'] = str(error)
            _save_receipt(journal, state, receipt)
            raise OSError(f'云端镜像已核验，但本地清理未完成；剩余副本和恢复记录保留在 {staging}') from error
        if os.path.lexists(target):
            receipt['status'] = 'new_working_copy_present'
            _save_receipt(journal, state, receipt)
            raise OSError('已清理核验过的旧副本，但其他程序重新创建了本地文件；新文件完整保留，请关闭占用程序后核对')
        receipt['status'] = 'released'
        receipt['files'] = len(verified['hashes'])
        receipt['bytes'] = sum(e['size'] for e in verified['inventory'].values() if e['kind'] == 'file')
        _save_receipt(journal, state, receipt)
        print('RELEASED_LOCAL\t' + relative + '\tfiles=' + str(receipt['files']) +
              '\tbytes=' + str(receipt['bytes']) + '\treceipt=' + str(journal))
        return 0
    except BaseException:
        if os.path.lexists(payload) and not os.path.lexists(target) and receipt['status'] != 'cleanup_incomplete':
            restore_target(staging, local, relative)
        raise
