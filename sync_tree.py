#!/usr/bin/env python3
"""One-way sync that keeps going when a cloud file cannot be hydrated."""

import argparse
import concurrent.futures
import fnmatch
import os
from pathlib import Path
import shutil
import sys

ALWAYS_EXCLUDE_DIRS = {'.venv', '__pycache__', 'pycache', 'node_modules', '.pytest_cache', '.mypy_cache', '.ruff_cache'}
ALWAYS_EXCLUDE_FILES = {'*.researchsync-partial', '*.pyc', '.DS_Store'}
TEMP_DIRS = {'tmp', 'temp', '.tmp', '.temp'}
CODEX_DIRS = {'.codex', '.agents'}
CLAUDE_DIRS = {'.claude'}
CODEX_FILES = {'AGENTS.md'}
CLAUDE_FILES = {'CLAUDE.md', '.mcp.json'}
TEMP_FILES = {'*.tmp', '*.temp', '*.swp', '*.swo', '*~', '*.log'}
LATEX_EXCLUDE_FILES = {
    '*.aux', '*.log', '*.synctex.gz', '*.fls', '*.fdb_latexmk', '*.out',
    '*.toc', '*.lof', '*.lot', '*.blg', '*.bcf', '*.run.xml', '*.nav',
    '*.snm', '*.vrb', '*.xdv', '*.acn', '*.acr', '*.alg', '*.glg',
    '*.glo', '*.ist', '*.ilg', '*.idx', '*.synctex(busy)', '.DS_Store',
}
LATEX_EXCLUDE_DIRS = {'_minted-'}


def excluded(name, latex):
    patterns = ALWAYS_EXCLUDE_FILES | (LATEX_EXCLUDE_FILES if latex else set())
    return any(fnmatch.fnmatch(name, pattern) for pattern in patterns)


def excluded_relative(name, latex, skip_codex=False, skip_claude=False,
                      include_temp=False, directory=False):
    parts = Path(name).parts
    if not parts:
        return False
    folders = parts if directory else parts[:-1]
    if any(part in ALWAYS_EXCLUDE_DIRS for part in folders):
        return True
    if latex and any(any(part.startswith(prefix) for prefix in LATEX_EXCLUDE_DIRS)
                     for part in folders):
        return True
    if not include_temp and any(part in TEMP_DIRS for part in folders):
        return True
    if skip_codex and (any(part in CODEX_DIRS for part in folders)
                       or (not directory and parts[-1] in CODEX_FILES)):
        return True
    if skip_claude and (any(part in CLAUDE_DIRS for part in folders)
                        or (not directory and parts[-1] in CLAUDE_FILES)):
        return True
    if directory:
        return False
    if len(parts) >= 2 and parts[-2:] == ('.claude', 'settings.local.json'):
        return True
    if excluded(parts[-1], latex):
        return True
    return not include_temp and any(fnmatch.fnmatch(parts[-1], pattern)
                                    for pattern in TEMP_FILES)


def transfer(pair):
    source, destination, dry_run = pair
    temporary = destination.with_name(destination.name + '.researchsync-partial')
    try:
        if source.is_symlink():
            if not destination.exists() and not destination.is_symlink() and not dry_run:
                destination.symlink_to(os.readlink(source))
            return 'skipped', None
        source_stat = source.stat()
        if destination.exists():
            target_stat = destination.stat()
            if target_stat.st_mtime_ns > source_stat.st_mtime_ns + 1_000_000_000:
                return 'skipped', None
            if target_stat.st_size == source_stat.st_size and abs(target_stat.st_mtime_ns - source_stat.st_mtime_ns) <= 1_000_000_000:
                return 'skipped', None
        if dry_run:
            return 'copied', None
        if temporary.exists():
            temporary.unlink()
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
        return 'copied', None
    except OSError as error:
        try:
            temporary.unlink()
        except OSError:
            pass
        return 'failed', (str(source), str(error))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--exclude-latex', action='store_true')
    parser.add_argument('--skip-codex', action='store_true')
    parser.add_argument('--skip-claude', action='store_true')
    parser.add_argument('--include-temp', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    counts = {'copied': 0, 'skipped': 0, 'failed': 0}
    errors = []
    pairs = []
    for root, dirs, files in os.walk(args.source):
        relative = Path(root).relative_to(args.source)
        dirs[:] = [name for name in dirs if not excluded_relative(
            (relative / name).as_posix(), args.exclude_latex,
            args.skip_codex, args.skip_claude, args.include_temp, directory=True)]
        target_root = args.destination / Path(root).relative_to(args.source)
        if not args.dry_run:
            target_root.mkdir(parents=True, exist_ok=True)
        for name in files:
            if not excluded_relative((relative / name).as_posix(), args.exclude_latex,
                                     args.skip_codex, args.skip_claude, args.include_temp):
                pairs.append((Path(root) / name, target_root / name, args.dry_run))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        for status, error in executor.map(transfer, pairs):
            counts[status] += 1
            if error:
                errors.append(error)
    for path, error in errors:
        print(f'FAILED\t{path}\t{error}')
    print(f"copied={counts['copied']} skipped={counts['skipped']} failed={counts['failed']}")
    return 2 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
