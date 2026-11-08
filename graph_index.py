"""Device-local OneDrive metadata/delta index. Never downloads file contents."""
import base64
import ctypes
from datetime import datetime
import gzip
import hashlib
import http.client
import json
import os
import re
from pathlib import Path, PurePosixPath
import sqlite3
import stat
import subprocess
import time
from urllib.parse import quote, urlencode, urlsplit

_NATIVE = None

class IndexError(OSError):
    pass

class AuthenticationRequired(IndexError):
    pass

class HTTPFailure(IndexError):
    def __init__(self, status, code='unknown'):
        self.status, self.code = status, code
        super().__init__(f'OneDrive 元数据查询失败（HTTP {status}，{code}）')


def credentials(helper):
    """Only stdout pipes carry credentials; never argv, logs or sync state."""
    try:
        result = subprocess.run([str(helper), '--token'], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=45, check=False)
    except subprocess.SubprocessError:
        raise AuthenticationRequired('OneDrive 后台登录超时；本次同步已停止，不会打开浏览器。') from None
    if result.returncode:
        raise AuthenticationRequired('OneDrive 尚未连接或登录已失效；请在设置中连接。后台任务不会打开浏览器。')
    try:
        value = json.loads(result.stdout)
        if not isinstance(value, dict) or not value.get('access_token') or not value.get('drive_id'):
            raise ValueError('incomplete credentials')
        return value
    except (ValueError, TypeError):
        raise AuthenticationRequired('OneDrive 登录信息不可用；请在设置中重新连接。') from None


class GraphClient:
    def __init__(self, token, progress=None):
        self.token = token
        self.connection = None
        self.requests = self.retries = self.wire_bytes = 0
        self.progress = progress or (lambda *args: None)

    def close(self):
        if self.connection:
            self.connection.close()
        self.connection = None
        self.token = ''

    def get(self, url):
        parsed = urlsplit(url)
        if (parsed.scheme != 'https' or parsed.hostname != 'graph.microsoft.com'
                or parsed.port not in (None, 443) or not parsed.path.startswith('/v1.0/')
                or '/content' in parsed.path or parsed.username or parsed.password):
            raise IndexError('已拒绝不安全的云端元数据地址')
        target = parsed.path + ('?' + parsed.query if parsed.query else '')
        for attempt in range(3):
            self.progress('WAIT', str(self.requests + 1))
            try:
                if self.connection is None:
                    self.connection = http.client.HTTPSConnection('graph.microsoft.com', timeout=30)
                self.requests += 1
                self.connection.request('GET', target, headers={
                    'Authorization': 'Bearer ' + self.token, 'Accept': 'application/json',
                    'Accept-Encoding': 'gzip', 'Connection': 'keep-alive'})
                response = self.connection.getresponse()
                wire = response.read()
                self.wire_bytes += len(wire)
                raw = gzip.decompress(wire) if response.getheader('Content-Encoding') == 'gzip' else wire
                if response.status >= 400:
                    try:
                        code = json.loads(raw).get('error', {}).get('code', 'unknown')
                    except (ValueError, AttributeError):
                        code = 'unknown'
                    if response.status in (429, 500, 502, 503, 504) and attempt < 2:
                        self.retries += 1
                        self.progress('RETRY', str(self.retries))
                        try:
                            delay = min(30, max(1, float(response.getheader('Retry-After', '2'))))
                        except ValueError:
                            delay = 2
                        time.sleep(delay)
                        continue
                    raise HTTPFailure(response.status, code)
                value = json.loads(raw)
                if not isinstance(value, dict):
                    raise IndexError('OneDrive 元数据响应格式无效')
                return value
            except (OSError, http.client.HTTPException) as error:
                if isinstance(error, IndexError):
                    raise
                if self.connection:
                    self.connection.close()
                self.connection = None
                if attempt == 2:
                    raise IndexError('OneDrive 元数据服务暂时不可用；已保留旧索引，本次不会把缓存当作最新结果') from None
                self.retries += 1
                self.progress('RETRY', str(self.retries))
                time.sleep(1)
        raise IndexError('OneDrive 元数据请求未完成')


def component(value):
    if not isinstance(value, str) or value in ('', '.', '..') or '/' in value or '\\' in value or '\0' in value:
        raise IndexError('OneDrive 返回了不安全的文件名')
    return value


def timestamp_ns(value):
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() * 1_000_000_000)
    except ValueError:
        return None


def fingerprint(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def content_hashes(path):
    global _NATIVE
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or getattr(before, 'st_flags', 0) & 0x40000000:
        raise IndexError('本地文件不可直接读取，未触发云端下载')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        if fingerprint(opened) != fingerprint(before):
            raise IndexError('本地文件在读取前发生变化')
        library = Path(__file__).with_name('QuickXorHash.dylib')
        if library.is_file():
            if _NATIVE is None:
                _NATIVE = ctypes.CDLL(str(library), use_errno=True)
                _NATIVE.pathsync_hash_fd.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
            native = _NATIVE
            quick = (ctypes.c_ubyte * 20)()
            sha = (ctypes.c_ubyte * 32)()
            if native.pathsync_hash_fd(fd, quick, sha):
                raise OSError(ctypes.get_errno(), '本地文件读取失败')
            result = {'quickXorHash': base64.b64encode(bytes(quick)).decode(), 'sha256': bytes(sha).hex()}
        else:
            # Portable test/source-build fallback; packaged apps ship the native implementation.
            lanes = bytearray(160)
            pos = length = 0
            sha = hashlib.sha256()
            while True:
                block = os.read(fd, 262144)
                if not block:
                    break
                sha.update(block)
                length += len(block)
                for byte in block:
                    lanes[pos] ^= byte
                    pos = (pos + 1) % 160
            quick = bytearray(20)
            for index, byte in enumerate(lanes):
                shift = index * 11 % 160
                offset, bit = divmod(shift, 8)
                quick[offset] ^= byte << bit & 255
                if bit:
                    quick[(offset + 1) % 20] ^= byte >> (8 - bit)
            for index in range(8):
                quick[12 + index] ^= length >> (index * 8) & 255
            result = {'quickXorHash': base64.b64encode(quick).decode(), 'sha256': sha.hexdigest()}
        if fingerprint(os.fstat(fd)) != fingerprint(opened) or fingerprint(path.lstat()) != fingerprint(opened):
            raise IndexError('本地文件在哈希计算期间发生变化')
        return {**result, 'signature': fingerprint(opened)}
    finally:
        os.close(fd)


class GraphIndex:
    def __init__(self, database, local_root, cloud_root, drive_id, remote_path, fetch, progress=None):
        self.path = Path(database)
        self.local = Path(local_root)
        self.cloud = Path(cloud_root)
        self.fetch = fetch
        self.progress = progress or (lambda *args: None)
        self.fresh = False
        self.stats = {'pages': 0, 'changed': 0, 'rebuilt': 0, 'hash_hits': 0, 'hash_reads': 0, 'mapped_names': 0}
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.path.is_symlink():
            raise IndexError('索引路径不可为符号链接')
        self.db = sqlite3.connect(self.path, timeout=20)
        os.chmod(self.path, 0o600)
        self.db.execute('PRAGMA journal_mode=DELETE')
        self.db.executescript('''
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, parent TEXT, name TEXT NOT NULL,
                is_folder INTEGER NOT NULL, size INTEGER, quick TEXT, mtime INTEGER, etag TEXT);
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent);
            CREATE TABLE IF NOT EXISTS local_hashes(name TEXT PRIMARY KEY, signature TEXT NOT NULL,
                quick TEXT NOT NULL, sha TEXT NOT NULL);
        ''')
        if any(part in ('', '.', '..') for part in remote_path.split('/')) or not remote_path:
            raise IndexError('云端索引路径无效')
        root_info = self.cloud.stat()
        self.binding = json.dumps({'version': 1, 'local': str(self.local), 'cloud': str(self.cloud),
            'cloudRootDevice': root_info.st_dev, 'cloudRootInode': root_info.st_ino,
            'drive': drive_id, 'remote': remote_path}, sort_keys=True)
        self.drive_id, self.remote_path = drive_id, remote_path
        self.entries = {}

    def close(self):
        self.db.close()

    def meta(self, name):
        row = self.db.execute('SELECT value FROM meta WHERE key=?', (name,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)', (key, value))

    def _apply(self, item, root_id):
        if not isinstance(item, dict):
            raise IndexError('云端记录格式无效')
        identity = item.get('id')
        if not isinstance(identity, str) or not identity:
            raise IndexError('云端记录缺少文件标识')
        if 'deleted' in item:
            if identity == root_id:
                raise IndexError('云端同步目录已删除；请核对路径设置')
            self.db.execute('''WITH RECURSIVE descendants(id) AS
                (SELECT id FROM items WHERE id=? UNION SELECT items.id FROM items
                 JOIN descendants ON items.parent=descendants.id)
                DELETE FROM items WHERE id IN (SELECT id FROM descendants)''', (identity,))
            return
        name = component(item.get('name'))
        folder = 'folder' in item
        if not folder and 'file' not in item:
            raise IndexError('云端出现未识别的文件类型，索引未推进')
        parent_info = item.get('parentReference', {})
        if not isinstance(parent_info, dict):
            raise IndexError('云端父目录信息无效')
        parent = parent_info.get('id')
        size = item.get('size', 0)
        if not isinstance(size, int) or size < 0:
            raise IndexError('云端文件大小无效')
        file = item.get('file', {})
        if not isinstance(file, dict) or not isinstance(file.get('hashes', {}), dict):
            raise IndexError('云端哈希记录格式无效')
        quick = file.get('hashes', {}).get('quickXorHash')
        if quick:
            try:
                if len(base64.b64decode(quick, validate=True)) != 20:
                    raise ValueError()
            except (ValueError, TypeError):
                raise IndexError('云端内容哈希格式无效') from None
        filesystem = item.get('fileSystemInfo', {})
        if not isinstance(filesystem, dict):
            raise IndexError('云端文件日期信息无效')
        mtime = timestamp_ns(filesystem.get('lastModifiedDateTime'))
        self.db.execute('INSERT OR REPLACE INTO items VALUES (?,?,?,?,?,?,?,?)',
                        (identity, parent, name, int(folder), size, quick, mtime, item.get('eTag')))

    def _entries(self, root_id):
        rows = {row[0]: row for row in self.db.execute('SELECT * FROM items')}
        paths = {root_id: ''}
        def relative(identity, seen=None):
            if identity in paths:
                return paths[identity]
            seen = set() if seen is None else seen
            if identity in seen or identity not in rows:
                raise IndexError('云端目录索引不完整或存在循环；已保留原索引')
            seen.add(identity)
            row = rows[identity]
            parent = relative(row[1], seen)
            paths[identity] = parent + '/' + row[2] if parent else row[2]
            return paths[identity]
        entries = {}
        for identity, row in rows.items():
            if row[3]:
                continue
            name = relative(identity)
            # OneDrive can expose a colon as a numeric entity in Graph while
            # File Provider exposes ':'. Prefer an exact existing mirror name;
            # translate only this observed encoding and reject every collision.
            decoded = re.sub(r'&#(?:x0*3a|0*58);', ':', name, flags=re.IGNORECASE)
            if decoded != name and not os.path.lexists(self.cloud / name):
                name = decoded
                self.stats['mapped_names'] += 1
            if name in entries:
                raise IndexError('云端目录出现同名记录，索引未推进')
            entries[name] = {'id': identity, 'size': row[4], 'quick': row[5],
                             'mtime': row[6], 'etag': row[7]}
        return entries

    def refresh(self):
        started = time.monotonic()
        self.fresh = False
        same_binding = self.meta('binding') == self.binding
        root_id = self.meta('root') if same_binding else None
        cursor = self.meta('cursor') if same_binding else None
        if not root_id:
            folder = self.fetch('https://graph.microsoft.com/v1.0/drives/' + quote(self.drive_id, safe='')
                + '/root:/' + quote(self.remote_path, safe='/') + '?$select=id,name,folder')
            if 'folder' not in folder or not isinstance(folder.get('id'), str):
                raise IndexError('云端同步目录不存在或不是文件夹')
            root_id = folder['id']
        initial = ('https://graph.microsoft.com/v1.0/drives/' + quote(self.drive_id, safe='')
            + '/items/' + quote(root_id, safe='') + '/delta?' + urlencode({
                '$select': 'id,name,size,file,folder,parentReference,deleted,eTag,fileSystemInfo', '$top': '1000'}))
        self.db.commit()
        for rebuild_attempt in range(2):
            try:
                with self.db:
                    self.db.execute('BEGIN IMMEDIATE')
                    if not cursor:
                        self.db.execute('DELETE FROM items')
                        self.db.execute('DELETE FROM local_hashes')
                        self.stats['rebuilt'] = 1
                    link = cursor or initial
                    visited = set()
                    while True:
                        if not isinstance(link, str) or not link:
                            raise IndexError('云端分页地址格式无效，索引未推进')
                        if link in visited:
                            raise IndexError('云端分页地址重复，索引未推进')
                        visited.add(link)
                        page = self.fetch(link)
                        values = page.get('value')
                        if not isinstance(values, list):
                            raise IndexError('云端增量响应无效')
                        for item in values:
                            self._apply(item, root_id)
                        self.stats['pages'] += 1
                        self.stats['changed'] += len(values)
                        self.progress('PAGE', str(self.stats['pages']), str(self.stats['changed']))
                        if '@odata.nextLink' in page:
                            link = page['@odata.nextLink']
                            continue
                        next_cursor = page.get('@odata.deltaLink')
                        if not isinstance(next_cursor, str) or not next_cursor:
                            raise IndexError('云端未返回增量游标，索引未推进')
                        # Validate even a stored cursor before accepting it; bearer tokens
                        # must never be sent to a host supplied by an untrusted response.
                        parsed = urlsplit(next_cursor)
                        if (parsed.scheme != 'https' or parsed.hostname != 'graph.microsoft.com'
                                or parsed.port not in (None, 443) or parsed.username or parsed.password
                                or not parsed.path.startswith('/v1.0/') or '/content' in parsed.path):
                            raise IndexError('云端增量游标无效')
                        entries = self._entries(root_id)
                        self.set_meta('binding', self.binding)
                        self.set_meta('root', root_id)
                        self.set_meta('cursor', next_cursor)
                        self.set_meta('updated', str(time.time()))
                        break
                self.entries = entries
                self.fresh = True
                self.stats['seconds'] = round(time.monotonic() - started, 4)
                return self.stats
            except HTTPFailure as error:
                if error.status != 410 or not cursor or rebuild_attempt:
                    raise
                cursor = None
        raise IndexError('云端索引重建失败')

    def local_hash(self, name, path):
        info = path.lstat()
        sig = fingerprint(info)
        row = self.db.execute('SELECT signature,quick,sha FROM local_hashes WHERE name=?', (name,)).fetchone()
        if row and json.loads(row[0]) == sig and stat.S_ISREG(info.st_mode):
            self.stats['hash_hits'] += 1
            return {'signature': sig, 'quickXorHash': row[1], 'sha256': row[2]}
        value = content_hashes(path)
        self.db.execute('INSERT OR REPLACE INTO local_hashes VALUES (?,?,?,?)',
                        (name, json.dumps(value['signature']), value['quickXorHash'], value['sha256']))
        self.stats['hash_reads'] += 1
        return value

    def verified_common(self, name, path, cloud_signature):
        """Equality-only optimization. It never chooses a winner or deletes files."""
        if not self.fresh or cloud_signature is None:
            return None
        remote = self.entries.get(name)
        if not remote or not remote['quick'] or remote['mtime'] is None:
            return None
        if remote['size'] != cloud_signature[0] or abs(remote['mtime'] - cloud_signature[1]) >= 1_000_000_000:
            return None
        local = self.local_hash(name, path)
        if local['signature'][2] == remote['size'] and local['quickXorHash'] == remote['quick']:
            return local['sha256']
        return None

    def flush_hashes(self):
        self.db.commit()
