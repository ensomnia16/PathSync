"""Verified File Provider package mapping. Never identify a package by suffix alone."""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import sync_cancel


def attribute(path, name):
    if sys.platform != 'darwin':
        return None
    result = subprocess.run(['/usr/bin/xattr', '-px', name, str(path)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode:
        return None
    try:
        return bytes.fromhex(result.stdout.decode())
    except ValueError:
        return None


def is_package(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode):
        return False
    finder = attribute(path, 'com.apple.FinderInfo')
    return bool(finder and len(finder) == 32 and int.from_bytes(finder[8:10], 'big') & 0x2000)


def safe(root, name):
    parts = Path(name).parts
    if not parts or Path(name).is_absolute() or '..' in parts:
        raise OSError('包路径无效，已保留原文件')
    path = root
    for part in parts:
        path /= part
        if path.is_symlink():
            raise OSError('包路径包含符号链接，已保留原文件')
    return path


def resolve(root, name):
    """A literal .pkgf file wins. Otherwise require native package evidence.

    File Provider's before-bounce attribute is the original name before its
    collision rename. A directory merely ending in ' 2' is not evidence.
    """
    if not name.endswith('.pkgf'):
        return None
    raw = safe(root, name)
    if os.path.lexists(raw):
        return None
    original = raw.name[:-5]
    parent = raw.parent
    if not parent.is_dir():
        return None
    candidates = []
    with os.scandir(parent) as entries:
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False):
                continue
            path = parent / entry.name
            if not is_package(path):
                continue
            before = attribute(path, 'com.apple.fileprovider.before-bounce#PX')
            if entry.name == original or before == original.encode('utf-8') + b'\0':
                candidates.append(path.relative_to(root).as_posix())
    if len(candidates) > 1:
        raise OSError('同一云端包对应多个本机包目录；已保留所有版本，请在 OneDrive 中核对重名目录')
    return candidates[0] if candidates else None


def snapshot(path, digest, check):
    """Include empty directories, links (never followed), forks and user metadata."""
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_dir():
        raise OSError('包位置被普通文件或符号链接占用；已保留原文件')
    result = []
    def walk(current):
        check()
        before = current.lstat()
        relative = current.relative_to(path).as_posix()
        if stat.S_ISLNK(before.st_mode):
            result.append((relative, 'link', os.readlink(current)))
            return
        if not (stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode)):
            raise OSError('包内含特殊文件，已保留原包')
        attrs = {}
        if sys.platform == 'darwin':
            names = subprocess.run(['/usr/bin/xattr', str(current)], check=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().splitlines()
            for key in names:
                # Provider transport, quarantine and access metadata do not
                # describe the document; never transport them into the work copy.
                if key.startswith(('com.apple.fileprovider.', 'com.apple.lastuseddate', 'com.apple.quarantine')):
                    continue
                value = attribute(current, key)
                if value is None:
                    raise OSError('包扩展属性读取期间发生变化，请重试')
                attrs[key] = hashlib.sha256(value).hexdigest()
        mode = stat.S_IMODE(before.st_mode)
        if stat.S_ISDIR(before.st_mode):
            result.append((relative, 'dir', mode, attrs))
            for child in sorted(current.iterdir()):
                walk(child)
        else:
            result.append((relative, 'file', mode, digest(current), attrs))
        after = current.lstat()
        if (before.st_ino, before.st_mtime_ns, before.st_ctime_ns, before.st_size) != (after.st_ino, after.st_mtime_ns, after.st_ctime_ns, after.st_size):
            raise OSError('包在读取期间发生变化，本次未覆盖任何版本')
    walk(path)
    return hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()


def publish_exclusive(source, destination):
    """Atomic no-replace publication; a late arrival is never overwritten."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        rename = library.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = rename(os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    elif hasattr(library, 'renameat2'):
        rename = library.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    else:
        raise OSError('当前系统不支持包的安全发布；未修改目标')
    if result:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), str(destination))


def copy_missing(source_root, destination_root, name, digest, check):
    source, destination = safe(source_root, name), safe(destination_root, name)
    expected = snapshot(source, digest, check)
    if expected is None:
        raise OSError('OneDrive 包目录已移动，请刷新后重试')
    if os.path.lexists(destination):
        raise FileExistsError('包的目标已存在；未覆盖')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A private sibling stays on the same filesystem for atomic publication.
    stage = Path(tempfile.mkdtemp(prefix='.pathsync-package-', suffix='.researchsync-partial', dir=destination.parent))
    try:
        staged = stage / 'content'
        if sys.platform == 'darwin':
            # ditto preserves resource forks, Finder package flags and internal links.
            sync_cancel.run_copy(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl', str(source), str(staged)])
        else:
            shutil.copytree(source, staged, symlinks=True)
        check()
        if snapshot(staged, digest, check) != expected or snapshot(source, digest, check) != expected:
            raise OSError('包复制后内容核验不一致；原文件未修改')
        if sys.platform == 'darwin':
            # Only remove provider bookkeeping from our owned, unpublished copy.
            for current, directories, files in os.walk(staged, followlinks=False):
                for item in [Path(current)] + [Path(current) / f for f in files]:
                    if item.is_symlink():
                        continue
                    attrs = subprocess.run(['/usr/bin/xattr', str(item)], check=True, stdout=subprocess.PIPE).stdout.decode().splitlines()
                    for key in attrs:
                        if key.startswith(('com.apple.fileprovider.', 'com.apple.lastuseddate', 'com.apple.quarantine')):
                            subprocess.run(['/usr/bin/xattr', '-d', key, str(item)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        check()
        # Revalidate every ancestor immediately before the exclusive rename.
        if safe(destination_root, name) != destination:
            raise OSError('包目标路径已改变')
        publish_exclusive(staged, destination)
        return expected
    finally:
        shutil.rmtree(stage)
