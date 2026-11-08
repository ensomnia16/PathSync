#!/usr/bin/env python3
"""Agent-facing CLI. Policy reads are local; transfers use the GUI's signed core."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import unicodedata
import uuid

sys.dont_write_bytecode = True
from sync_tree import ExcludeRules, IGNORE_FILE
import cloud_only

SUPPORT = Path.home() / 'Library/Application Support/ResearchSync'
SCHEMA = 1


class PolicyError(ValueError):
    pass


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_json(path):
    """Bounded stable read; never hydrate a rule/config placeholder."""
    path = Path(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > 1_000_000:
        raise PolicyError('配置必须是小于 1 MB 的普通 JSON 文件：' + str(path))
    if getattr(before, 'st_flags', 0) & 0x40000000:
        raise PolicyError('规则文件仅在线；请先在 OneDrive 下载这一个配置文件，CLI 本次未下载文件。')
    def timeout(_signum, _frame):
        raise TimeoutError('读取配置超过 20 秒，未使用本地旧规则代替。')
    previous = signal.signal(signal.SIGALRM, timeout)
    signal.setitimer(signal.ITIMER_REAL, 20)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as source:
            opened = os.fstat(source.fileno())
            if fingerprint(opened) != fingerprint(before):
                raise PolicyError('配置在打开时发生变化，请重试。')
            data = source.read(1_000_001)
            if len(data) > 1_000_000 or fingerprint(os.fstat(source.fileno())) != fingerprint(opened) or fingerprint(path.lstat()) != fingerprint(opened):
                raise PolicyError('配置在读取时发生变化，请重试。')
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    result = json.loads(data.decode('utf-8-sig'))
    if not isinstance(result, dict):
        raise PolicyError('配置顶层必须是 JSON 对象。')
    return result


def absolute(value):
    return Path(os.path.abspath(os.path.expanduser(str(value))))


def relative(path, root):
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return None


def policy(config_path):
    config = read_json(config_path)
    root_value = config.get('oneDriveRoot')
    if not isinstance(root_value, str) or not root_value:
        raise PolicyError('尚未配置 OneDrive 根目录。')
    root = absolute(root_value).resolve()
    rules_path = root / 'PathSync-Exclusions.json'
    document = read_json(rules_path)
    entries = document.get('pairs')
    if type(document.get('version')) is not int or document['version'] != 1 or not isinstance(entries, dict):
        raise PolicyError('OneDrive 根排除配置版本或格式无效。')
    if document.get('excludeLatexIntermediates') is not False:
        raise PolicyError('根配置仍启用了旧的批量过滤开关，不能推断实际排除范围。')
    for entry in entries.values():
        if (not isinstance(entry, dict) or not isinstance(entry.get('excludeRules'), str)
                or '\0' in entry['excludeRules']
                or not all(entry.get(key) is True for key in ('syncCodexFiles', 'syncClaudeFiles', 'syncTemporaryFiles'))):
            raise PolicyError('根配置中的排除规则或旧过滤开关无效。')
        if sum(len(line.encode()) + 11 for line in entry['excludeRules'].splitlines()) > 750_000:
            raise PolicyError('根配置中的排除规则过大。')
    raw_pairs = config.get('pairs')
    if not isinstance(raw_pairs, list):
        raise PolicyError('本机路径组配置无效。')
    pairs = []
    seen_ids = set()
    for pair in raw_pairs:
        if not isinstance(pair, dict):
            raise PolicyError('本机路径组格式无效。')
        identity = str(uuid.UUID(pair['id']))
        if identity in seen_ids:
            raise PolicyError('本机路径组 ID 重复。')
        seen_ids.add(identity)
        local_value, cloud_value = pair.get('localPath'), pair.get('cloudPath')
        if not isinstance(local_value, str) or not isinstance(cloud_value, str):
            raise PolicyError('本机路径组目录无效。')
        key = relative(absolute(cloud_value).resolve(), root) if cloud_value else None
        key = unicodedata.normalize('NFC', key) if key else None
        entry = entries.get(key)
        # Disabled or incomplete pairs are still visible, and never reported
        # as eligible output locations. An enabled pair needs its root policy.
        ready = bool(local_value and cloud_value and key not in (None, '.'))
        if pair.get('enabled') and (not ready or entry is None):
            raise PolicyError('OneDrive 根配置缺少路径组规则：' + str(pair.get('name', identity)))
        rules = [] if entry is None else [line.strip() for line in entry['excludeRules'].splitlines()
                                        if line.strip() and not line.strip().startswith(('#', '!'))]
        stored_cloud_paths = pair.get('cloudOnlyPaths', [])
        if not isinstance(stored_cloud_paths, list) or any(not isinstance(value, str) for value in stored_cloud_paths):
            raise PolicyError('本机仅云端子路径格式无效。')
        cloud_paths = list(cloud_only.validate_policy(stored_cloud_paths))
        if any(cloud_only.contains(prefix, (other,)) for prefix in cloud_paths for other in cloud_paths if prefix != other):
            raise PolicyError('本机仅云端子路径存在嵌套，请核对设置。')
        pairs.append({'id': identity, 'name': str(pair.get('name', identity)),
                      'enabled': pair.get('enabled') is True, 'configured': ready and entry is not None,
                      'direction': pair.get('scheduledDirection', 'upload'),
                      'localPath': local_value, 'cloudPath': cloud_value, 'policyKey': key,
                      'excludeRules': rules, 'cloudOnlyPaths': cloud_paths})
    return {'schemaVersion': SCHEMA, 'source': str(rules_path), 'configSource': str(config_path),
            'scope': 'this_mac', 'pairs': pairs,
            'protocolProtections': ['*.researchsync-partial (including ancestor folders)',
                                    'root .pathsyncignore', 'symbolic links'],
            'note': '规则排除和仅云端均暂停本机上传、下载及删除传播；本报告不证明文件已上传服务器。'}


def select_pair(pairs, value):
    if value is None:
        return None
    canonical = unicodedata.normalize('NFC', value)
    found = [pair for pair in pairs if pair['id'].lower() == value.lower()
             or unicodedata.normalize('NFC', pair['name']) == canonical]
    if len(found) != 1:
        raise PolicyError('路径组名称或 ID 不存在或不唯一；未执行同步：' + value)
    return found[0]


def check_path(snapshot, value, directory=False):
    path = absolute(value)
    resolved = path.resolve()
    matches = []
    for pair in snapshot['pairs']:
        for side, field in (('local', 'localPath'), ('cloud', 'cloudPath')):
            if not pair[field]:
                continue
            root = absolute(pair[field])
            name = relative(path, root)
            canonical_name = relative(resolved, root.resolve())
            if name is None and canonical_name is None:
                continue
            name = canonical_name if name is None else name
            cursor = root
            links = []
            for part in Path(name).parts:
                cursor /= part
                if cursor.is_symlink():
                    links.append(str(cursor))
            if canonical_name is None or links:
                matches.append((pair, side, name, links or [str(path)]))
            else:
                matches.append((pair, side, name, []))
    result = {'schemaVersion': SCHEMA, 'path': str(path), 'resolvedPath': str(resolved),
              'safeForImportantOutput': False, 'synchronizationVerified': False,
              'policySource': snapshot['source'], 'matchedRules': [], 'cloudOnlyPaths': []}
    if not matches:
        return {**result, 'classification': 'outside_sync_scope', 'reason': '不在 PathSync 管理范围；需沿用项目已有的 Git、发布或备份约定。'}, 4
    if len(matches) != 1:
        raise PolicyError('路径同时落入多个同步根目录，不能安全判断：' + str(path))
    pair, side, name, links = matches[0]
    result.update(pair={'id': pair['id'], 'name': pair['name']}, side=side, relativePath=name)
    is_directory = directory or path.is_dir()
    rules = [rule for rule in pair['excludeRules'] if ExcludeRules([rule]).matches(name, directory=is_directory)]
    paused = [prefix for prefix in pair['cloudOnlyPaths'] if cloud_only.contains(name, (prefix,))]
    protocol = [part for part in Path(name).parts if part.endswith('.researchsync-partial')]
    if name == IGNORE_FILE and not is_directory:
        protocol.append('root .pathsyncignore')
    result.update(matchedRules=rules, cloudOnlyPaths=paused, protocolProtections=protocol, symbolicLinks=links)
    if links:
        code, reason, exit_code = 'symbolic_link', '路径含同步引擎不会跟随的符号链接。', 3
    elif protocol:
        code, reason, exit_code = 'protocol_protected', '命中 PathSync 协议保留路径，不能保存重要成果。', 3
    elif paused:
        code, reason, exit_code = 'cloud_only', '此 Mac 对该目录暂停上传与下载；不要把重要成果的唯一副本输出到本机工作目录。', 3
    elif rules:
        code, reason, exit_code = 'excluded', '命中 OneDrive 根排除规则；不要把重要成果的唯一副本输出到这里。', 3
    elif not pair['enabled'] or not pair['configured']:
        code, reason, exit_code = 'disabled_pair', '该路径组未启用或未配置完整。', 4
    elif side == 'cloud':
        code, reason, exit_code = 'cloud_mirror', '这是 OneDrive 镜像；日常生成成果应使用对应本机工作目录。', 4
    elif pair['direction'] not in ('merge', 'upload'):
        code, reason, exit_code = 'upload_disabled', '该路径组的保存方向不会上传本机修改。', 4
    else:
        code, reason, exit_code = 'normal_sync', '符合本机上传范围；路径检查不等于文件已上传服务器。', 0
        result['safeForImportantOutput'] = True
    return {**result, 'classification': code, 'reason': reason}, exit_code


def sync_running(support):
    try:
        with (support / 'sync.lock').open('r+') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
    except FileNotFoundError:
        pass
    return False


def request_stop(support=SUPPORT):
    if not sync_running(support):
        return {'schemaVersion': SCHEMA, 'ok': True, 'state': 'idle', 'message': '当前没有正在运行的同步。'}
    active = read_json(support / 'active-sync.json')
    uuid.UUID(active['runID'])
    if type(active.get('pid')) is not int or active['pid'] <= 0:
        raise PolicyError('当前运行信息无效，未发送停止请求。')
    os.kill(active['pid'], 0)
    if read_json(support / 'active-sync.json') != active:
        raise PolicyError('同步任务已切换，请重试。')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=support, prefix='stop-sync.', delete=False) as target:
            temporary = Path(target.name)
            json.dump(active, target)
            target.flush(); os.fsync(target.fileno())
        os.replace(temporary, support / 'stop-sync.json')
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return {'schemaVersion': SCHEMA, 'ok': True, 'state': 'stop_requested', 'runID': active['runID'],
            'message': '已请求停止本次运行；已完成文件保留。请用 status 确认任务结束。'}


def native_path():
    candidate = Path(__file__).resolve().parent.parent / 'MacOS/PathSync'
    return candidate if candidate.is_file() else Path('/Applications/路径同步.app/Contents/MacOS/PathSync')


def invoke(arguments, config_path):
    executable = native_path()
    if not executable.is_file():
        raise PolicyError('未找到已签名的 PathSync 同步核心；请先安装应用。')
    return subprocess.run([str(executable), *arguments, '--config', str(config_path)], capture_output=True, text=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description='PathSync agent CLI：共享同步核心、当前排除规则及输出路径检查。')
    parser.add_argument('--config', type=Path, default=SUPPORT / 'config.json')
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('rules', 'check-path', 'status', 'sync', 'preview', 'stop', 'version'):
        command = commands.add_parser(name)
        command.add_argument('--json', action='store_true')
        if name in ('rules', 'sync', 'preview'):
            command.add_argument('--pair', help='路径组名称或 UUID；不接受模糊匹配')
        if name == 'check-path':
            command.add_argument('path')
            command.add_argument('--directory', action='store_true', help='将尚未创建的路径按目录检查')
    args = parser.parse_args(argv)
    try:
        exit_code = 0
        if args.command == 'version':
            info = Path(__file__).resolve().parent.parent / 'Info.plist'
            if not info.is_file(): info = Path(__file__).with_name('Info.plist')
            result = {'schemaVersion': SCHEMA, 'version': plistlib.loads(info.read_bytes())['CFBundleShortVersionString']}
        elif args.command == 'stop':
            if args.config != SUPPORT / 'config.json':
                raise PolicyError('stop 只操作当前 Mac 的全局任务，不接受 --config。')
            result = request_stop()
        elif args.command == 'status':
            native = invoke(['--status'], args.config)
            if native.returncode: raise PolicyError(native.stderr.strip() or '读取状态失败。')
            result = {'schemaVersion': SCHEMA, **json.loads(native.stdout)}
        else:
            snapshot = policy(args.config)
            if args.command == 'check-path':
                result, exit_code = check_path(snapshot, args.path, args.directory)
            else:
                pair = select_pair(snapshot['pairs'], args.pair)
                if args.command == 'rules':
                    result = {**snapshot, 'pairs': [pair] if pair else snapshot['pairs']}
                else:
                    if pair and (not pair['enabled'] or not pair['configured']):
                        raise PolicyError('指定路径组未启用或配置不完整；未执行同步。')
                    arguments = ['--sync' if args.command == 'sync' else '--dry-run']
                    if pair: arguments += ['--pair', pair['id']]
                    native = invoke(arguments, args.config)
                    exit_code = native.returncode if native.returncode >= 0 else 1
                    result = {'schemaVersion': SCHEMA, 'ok': exit_code == 0, 'returnCode': exit_code,
                              'state': 'stopped' if exit_code == 130 else 'complete' if exit_code == 0 else 'incomplete',
                              'output': native.stdout.strip(), 'diagnostics': native.stderr.strip()}
        if args.json:
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        elif args.command == 'version': print(result['version'])
        else: print(json.dumps(result, ensure_ascii=False, indent=2))
        return exit_code
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        result = {'schemaVersion': SCHEMA, 'ok': False, 'error': str(error), 'state': 'unknown'}
        print(json.dumps(result, ensure_ascii=False) if args.json else 'PathSync：' + str(error))
        return 2


if __name__ == '__main__':
    sys.exit(main())
