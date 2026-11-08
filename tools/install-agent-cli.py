#!/usr/bin/env python3
"""Install a stable per-user CLI launcher and optional, explicitly requested guidance."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shlex
import tempfile

BEGIN = '<!-- PATHSYNC_AGENT_RULES_BEGIN -->'
END = '<!-- PATHSYNC_AGENT_RULES_END -->'


def atomic_write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('wb', dir=path.parent, prefix=path.name+'.', delete=False) as target:
            temporary = Path(target.name)
            target.write(data); target.flush(); os.fsync(target.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists(): temporary.unlink()


def merge_guidance(original, block):
    if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
        raise ValueError('现有 PathSync 规范标记不完整，已保留原文件。')
    if BEGIN in original:
        start = original.index(BEGIN); end = original.index(END) + len(END)
        if end < start: raise ValueError('现有 PathSync 规范标记顺序无效。')
        return original[:start] + block + original[end:]
    separator = '\n' if original.endswith('\n') else '\n\n' if original else ''
    return original + separator + block + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=Path('/Applications/路径同步.app'))
    parser.add_argument('--bin-dir', type=Path, default=Path.home()/'.local/bin')
    parser.add_argument('--instructions', action='store_true', help='also install output-path, canonical-file and version-management guidance for Codex')
    parser.add_argument('--codex-home', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home()/'.codex'))))
    args = parser.parse_args()
    cli = args.app / 'Contents/Resources/pathsync_cli.py'
    if not cli.is_file(): raise ValueError('此应用尚未包含 agent CLI；请先安装新版本。')
    launcher = args.bin_dir / 'pathsync'
    shell = '#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(cli)) + ' "$@"\n'
    if os.path.lexists(launcher) and launcher.read_bytes() != shell.encode():
        raise ValueError('命令路径已被其他内容占用，未覆盖：' + str(launcher))
    updates = []
    if args.instructions:
        guide = Path(__file__).resolve().parent.parent/'docs/agent-instructions.md'
        if not guide.is_file(): guide = Path(__file__).with_name('agent-instructions.md')
        text = guide.read_text()
        block = BEGIN + '\n' + text.rstrip() + '\n' + END
        paths = [args.codex_home/'AGENTS.md']
        override = args.codex_home/'AGENTS.override.md'
        if override.exists() and override.stat().st_size: paths.append(override)
        for path in paths:
            if path.is_symlink(): raise ValueError('规范文件是符号链接，未修改：' + str(path))
            old = path.read_bytes() if path.exists() else b''
            new = merge_guidance(old.decode('utf-8'), block).encode('utf-8')
            if new != old: updates.append((path, old, new))
    # Validate all guidance files before making any change.
    for path, old, new in updates:
        if old:
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
            backup = args.codex_home/'backups/pathsync'/(path.name+'.'+stamp+'.'+hashlib.sha256(old).hexdigest()[:12])
            atomic_write(backup, old, 0o600)
        atomic_write(path, new, (path.stat().st_mode & 0o777) if path.exists() else 0o600)
    atomic_write(launcher, shell.encode(), 0o755)
    print(json.dumps({'cli': str(launcher), 'instructionsUpdated': [str(item[0]) for item in updates]}, ensure_ascii=False))


if __name__ == '__main__': main()
