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
ALWAYS_EXCLUDE_FILES = {'*.researchsync-partial', '*.pyc'}
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
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    counts = {'copied': 0, 'skipped': 0, 'failed': 0}
    errors = []
    pairs = []
    for root, dirs, files in os.walk(args.source):
        dirs[:] = [name for name in dirs if name not in ALWAYS_EXCLUDE_DIRS
                   and not (args.exclude_latex and any(name.startswith(prefix) for prefix in LATEX_EXCLUDE_DIRS))]
        target_root = args.destination / Path(root).relative_to(args.source)
        if not args.dry_run:
            target_root.mkdir(parents=True, exist_ok=True)
        for name in files:
            if not excluded(name, args.exclude_latex):
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
