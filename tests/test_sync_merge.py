import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import re
import shutil
from datetime import datetime, timedelta, timezone
import unittest
from unittest import mock
import contextlib
import io


HELPER = Path(__file__).resolve().parents[1] / 'sync_merge.py'
sys.path.insert(0, str(HELPER.parent))
import sync_merge


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.local = self.root / 'local'
        self.cloud = self.root / 'cloud'
        self.local.mkdir()
        self.cloud.mkdir()
        self.state = self.root / 'state.json'

    def preserve_for_review(self, name='paper.tex'):
        """Keep both versions by hand, which leaves a review until it is acknowledged."""
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', name, '--choice', 'both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_merge(self, *extra, policy='ask'):
        arguments = [sys.executable, str(HELPER), str(self.local), str(self.cloud),
                     str(self.state), '--exclude-latex']
        if policy is not None:
            arguments.extend(['--conflict-policy', policy])
        return subprocess.run([*arguments, *extra],
                              capture_output=True, text=True, timeout=15)

    def test_default_keeps_both_versions_automatically(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge(policy='keep-both').returncode, 0)
        (self.local / 'paper.tex').write_text('local revision')
        (self.cloud / 'paper.tex').write_text('cloud revision')
        result = self.run_merge(policy=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('kept_both=1', result.stdout)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local revision')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'local revision')
        copies = list(self.local.glob('paper (cloud conflict *).tex'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_text(), 'cloud revision')
        self.assertEqual((self.cloud / copies[0].name).read_text(), 'cloud revision')
        backup = Path(result.stdout.split('backup=', 1)[1].splitlines()[0])
        self.assertEqual((backup / 'local.tex').read_text(), 'local revision')
        self.assertEqual((backup / 'cloud.tex').read_text(), 'cloud revision')
        # Automatic keep-both completes the sync: nothing waits for a review.
        state = json.loads(self.state.read_text())
        self.assertEqual(state['conflicts'], {})
        self.assertIn(copies[0].name, state['files'])
        self.assertIn(f'KEPT_BOTH\tpaper.tex\tcopy={copies[0].name}', result.stdout)
        self.assertNotIn('NEEDS_REVIEW', result.stdout)
        again = self.run_merge(policy='keep-both')
        self.assertEqual(again.returncode, 0)
        self.assertIn('reviews=0', again.stdout)
        self.assertNotIn('KEPT_BOTH\t', again.stdout)
        self.assertEqual(len(list(self.local.glob('paper (* conflict *).tex'))), 1)

    def test_automatic_keep_both_clears_reviews_left_by_earlier_runs(self):
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud')
        self.preserve_for_review()
        self.assertIn('paper.tex', json.loads(self.state.read_text())['conflicts'])
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('reviews=0', result.stdout)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})
        self.assertEqual(len(list(self.local.glob('paper (cloud conflict *).tex'))), 1)

    def test_existing_pending_conflict_is_kept_on_next_default_run(self):
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud')
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'local')
        self.assertEqual(len(list(self.local.glob('paper (cloud conflict *).tex'))), 1)

    def test_download_conflict_keeps_cloud_at_original_path(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge(policy='keep-both').returncode, 0)
        (self.local / 'paper.tex').write_text('local changed')
        (self.cloud / 'paper.tex').write_text('cloud changed')
        result = self.run_merge('--direction', 'download', policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud changed')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud changed')
        copies = list(self.local.glob('paper (local conflict *).tex'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_text(), 'local changed')
        self.assertEqual((self.cloud / copies[0].name).read_text(), 'local changed')

    def test_default_dry_run_plans_keep_both_without_writing(self):
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud')
        result = self.run_merge('--dry-run', policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('WOULD_KEEP_BOTH\tpaper.tex', result.stdout)
        self.assertFalse(self.state.exists())
        self.assertFalse(list(self.local.glob('paper (* conflict *).tex')))

    def snapshot_everything(self):
        """Every path, byte and timestamp under the test root, including state."""
        found = {}
        for path in sorted(self.root.rglob('*')):
            info = path.lstat()
            found[path.relative_to(self.root).as_posix()] = (
                path.read_bytes() if path.is_file() else None, info.st_mtime_ns, info.st_mode)
        return found

    def plan(self, result):
        lines = [line for line in result.stdout.splitlines() if line.startswith('PLAN_JSON\t')]
        self.assertEqual(len(lines), 1, result.stdout + result.stderr)
        return json.loads(lines[0].split('\t', 1)[1])

    def test_plan_json_lists_every_planned_action_without_writing(self):
        for name in ('keep.tex', 'gone.tex', 'both.tex', 'edited.tex'):
            (self.local / name).write_text('base ' + name)
        self.assertEqual(self.run_merge(policy='keep-both').returncode, 0)
        (self.local / 'new local.tex').write_text('fresh local')
        (self.cloud / 'sub').mkdir()
        (self.cloud / 'sub' / 'new cloud.tex').write_text('fresh cloud')
        (self.local / 'gone.tex').unlink()
        (self.local / 'both.tex').write_text('local side')
        (self.cloud / 'both.tex').write_text('cloud side')
        (self.cloud / 'edited.tex').write_text('cloud edit')
        before = self.snapshot_everything()
        result = self.run_merge('--dry-run', '--plan-json', policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot_everything(), before)
        plan = self.plan(result)
        actions = {(item['action'], item['name']) for item in plan['items']}
        self.assertEqual(actions, {
            ('upload', 'new local.tex'), ('download', 'sub/new cloud.tex'),
            ('download', 'edited.tex'), ('delete', 'gone.tex'), ('keep_both', 'both.tex')})
        deletion = next(item for item in plan['items'] if item['action'] == 'delete')
        self.assertEqual(deletion['side'], 'cloud')
        upload = next(item for item in plan['items'] if item['action'] == 'upload')
        self.assertEqual(upload['size'], len('fresh local'))
        self.assertEqual(plan['direction'], 'merge')
        self.assertEqual(plan['counts']['uploaded'], 1)
        self.assertEqual(plan['counts']['downloaded'], 2)
        self.assertEqual(plan['counts']['deleted'], 1)
        self.assertEqual(plan['counts']['kept_both'], 1)
        self.assertIn('uploaded=1 downloaded=2', result.stdout)

    def test_plan_json_reports_conflicts_reviews_and_skips(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge(policy='keep-both').returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        (self.cloud / 'paper.tex').write_text('cloud edit')
        (self.cloud / 'only cloud.tex').write_text('cloud')
        before = self.snapshot_everything()
        ask = self.run_merge('--dry-run', '--plan-json', '--direction', 'upload', policy='ask')
        self.assertEqual(ask.returncode, 2, ask.stdout + ask.stderr)
        self.assertEqual(self.snapshot_everything(), before)
        plan = self.plan(ask)
        self.assertEqual([(item['action'], item['name']) for item in plan['items']],
                         [('conflict', 'paper.tex')])
        self.assertEqual(plan['counts']['skipped'], 1)
        self.preserve_for_review()
        before = self.snapshot_everything()
        review = self.run_merge('--dry-run', '--plan-json')
        self.assertEqual(self.snapshot_everything(), before)
        items = self.plan(review)['items']
        self.assertEqual([item['action'] for item in items], ['review'])
        self.assertTrue(items[0]['copy'].startswith('paper (cloud conflict '))

    def test_preview_does_not_read_files_that_exist_on_one_side_only(self):
        unreadable = self.cloud / 'placeholder.pdf'
        unreadable.write_text('cloud only content')
        unreadable.chmod(0)
        self.addCleanup(unreadable.chmod, 0o600)
        result = self.run_merge('--dry-run', '--plan-json')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.plan(result)['items'],
                         [{'action': 'download', 'name': 'placeholder.pdf',
                           'size': len('cloud only content')}])
        self.assertFalse(self.state.exists())

    def test_plan_json_requires_dry_run(self):
        result = self.run_merge('--plan-json')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--plan-json requires --dry-run', result.stderr)
        self.assertFalse(self.state.exists())

    def backup_args(self, base):
        return ['--backup-root', str(base), '--backup-subpath', 'PathSync/Backups/pair']

    def test_backups_go_to_chosen_folder_and_restore_from_there(self):
        drive = self.root / 'drive'
        drive.mkdir()
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge(*self.backup_args(drive)).returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        result = self.run_merge(*self.backup_args(drive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        remote = drive / 'PathSync/Backups/pair/backups' / backup_id
        self.assertEqual((remote / 'content').read_text(), 'anchor')
        self.assertFalse((remote / sync_merge.PENDING_MOVE).exists())
        self.assertFalse((self.root / 'state-backups').exists())
        self.assertEqual(json.loads((remote / 'manifest.json').read_text())['sha256'],
                         hashlib.sha256(b'anchor').hexdigest())
        restored = self.run_merge('--restore', backup_id, *self.backup_args(drive))
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'anchor')

    def test_conflict_backups_use_chosen_folder(self):
        drive = self.root / 'drive'
        drive.mkdir()
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud')
        result = self.run_merge(*self.backup_args(drive), policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backup = Path(result.stdout.split('backup=', 1)[1].splitlines()[0])
        self.assertTrue(str(backup).startswith(
            str(drive.resolve() / 'PathSync/Backups/pair/conflict-backups')))
        self.assertEqual((backup / 'cloud.tex').read_text(), 'cloud')
        self.assertFalse((self.root / 'state-conflict-backups').exists())

    def test_offline_folder_keeps_backup_locally_then_moves_it(self):
        drive = self.root / 'offline drive'
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge(*self.backup_args(drive)).returncode, 0)
        (self.cloud / 'paper.tex').write_text('cloud edit')
        result = self.run_merge(*self.backup_args(drive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(drive.exists(), 'a missing backup folder must not be created')
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        local_copy = self.root / 'state-backups' / backup_id
        self.assertTrue((local_copy / sync_merge.PENDING_MOVE).exists())
        offline_restore = self.run_merge('--restore', backup_id, *self.backup_args(drive))
        self.assertEqual(offline_restore.returncode, 0, offline_restore.stdout + offline_restore.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'anchor')
        (self.local / 'paper.tex').write_text('cloud edit')
        drive.mkdir()
        moved = self.run_merge(*self.backup_args(drive))
        self.assertEqual(moved.returncode, 0, moved.stdout + moved.stderr)
        self.assertIn('BACKUPS_MOVED\t', moved.stdout)
        remote = drive / 'PathSync/Backups/pair/backups' / backup_id
        self.assertEqual((remote / 'content').read_text(), 'anchor')
        self.assertFalse((remote / sync_merge.PENDING_MOVE).exists())
        self.assertFalse(local_copy.exists())
        restored = self.run_merge('--restore', backup_id, *self.backup_args(drive))
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)

    def test_failed_remote_write_falls_back_to_local_copy(self):
        drive = self.root / 'drive'
        drive.mkdir()
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge(*self.backup_args(drive)).returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        args = mock.Mock(state=self.state, dry_run=False, local=self.local.resolve(),
                         cloud=self.cloud.resolve(), backup_root=drive,
                         backup_subpath='PathSync/Backups/pair', backup_retention_days=15)
        args.backups = sync_merge.BackupPlace(args)
        real_write = sync_merge.write_backup

        def failing_remote(directory, *rest, **options):
            if str(directory).startswith(str(drive.resolve())):
                directory.mkdir(parents=True)
                (directory / 'content').write_text('partial')
                raise OSError('provider rejected the write')
            return real_write(directory, *rest, **options)

        with mock.patch.object(sync_merge, 'write_backup', side_effect=failing_remote):
            backup_id = sync_merge.backup_file(args, self.cloud.resolve(), 'paper.tex',
                                               'cloud', 'overwrite', 15)
        local_copy = self.root / 'state-backups' / backup_id
        self.assertEqual((local_copy / 'content').read_text(), 'anchor')
        self.assertTrue((local_copy / sync_merge.PENDING_MOVE).exists())
        self.assertEqual(args.backups.find(backup_id), local_copy)
        self.assertFalse(args.backups.available)

    def test_migrate_moves_all_local_backups_after_verifying(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        result = self.run_merge()
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        (self.local / 'other.tex').write_text('local')
        (self.cloud / 'other.tex').write_text('cloud')
        kept = self.run_merge(policy='keep-both')
        conflict_backup = Path(kept.stdout.split('backup=', 1)[1].splitlines()[0])
        self.assertTrue(conflict_backup.exists())
        drive = self.root / 'drive'
        drive.mkdir()
        moved = self.run_merge('--migrate-backups', *self.backup_args(drive))
        self.assertEqual(moved.returncode, 0, moved.stdout + moved.stderr)
        # Two overwrite backups plus the pair of conflict originals.
        self.assertIn('backups_moved=3', moved.stdout)
        base = drive / 'PathSync/Backups/pair'
        self.assertEqual((base / 'backups' / backup_id / 'content').read_text(), 'anchor')
        relative = conflict_backup.relative_to(self.root / 'state-conflict-backups')
        self.assertEqual((base / 'conflict-backups' / relative / 'cloud.tex').read_text(), 'cloud')
        self.assertFalse((self.root / 'state-backups' / backup_id).exists())
        self.assertFalse(conflict_backup.exists())
        offline = self.run_merge('--migrate-backups', '--backup-root', str(self.root / 'missing'),
                                 '--backup-subpath', 'pair')
        self.assertEqual(offline.returncode, 2)

    def test_move_keeps_source_when_copy_does_not_verify(self):
        source = self.root / 'source-backup'
        source.mkdir()
        (source / 'content').write_text('payload')
        (source / 'manifest.json').write_text(json.dumps(
            {'sha256': hashlib.sha256(b'something else').hexdigest()}))
        target = self.root / 'remote' / 'backup'
        with self.assertRaises(OSError):
            sync_merge.move_verified(source, target)
        self.assertTrue((source / 'content').exists())
        self.assertFalse(target.exists())
        self.assertFalse(list((self.root / 'remote').glob('*.partial-*')))

    def test_backup_folder_cannot_overlap_sync_paths(self):
        for base, subpath in ((self.cloud, 'backups'), (self.root.parent, self.root.name)):
            result = self.run_merge('--backup-root', str(base), '--backup-subpath', subpath)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        inside = self.run_merge('--backup-root', str(self.cloud), '--backup-subpath', 'backups')
        self.assertIn('备份位置不能位于同步路径内', inside.stderr)
        self.assertFalse((self.cloud / 'backups').exists())
        self.assertFalse(self.state.exists())

    def test_preview_never_writes_to_backup_folder(self):
        drive = self.root / 'drive'
        drive.mkdir()
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        before = self.snapshot_everything()
        preview = self.run_merge('--dry-run', '--plan-json', *self.backup_args(drive))
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertEqual(self.snapshot_everything(), before)
        self.assertEqual(list(drive.iterdir()), [])

    def test_exclude_rules_follow_gitignore_subset(self):
        rules = sync_merge.ExcludeRules([
            '# comment', '', '*.pdf', 'data/raw/', '/build', 'figures/**/*.png',
            'notes?.md', '!keep.pdf'])
        self.assertTrue(rules.matches('paper.pdf'))
        self.assertTrue(rules.matches('chapters/deep/fig.pdf'))
        self.assertTrue(rules.matches('data/raw', directory=True))
        self.assertTrue(rules.matches('data/raw/sample.csv'))
        self.assertFalse(rules.matches('data/raw'), 'a trailing / matches folders only')
        self.assertFalse(rules.matches('other/data/raw/x.csv'), 'a middle / anchors at the root')
        self.assertTrue(rules.matches('build/out.txt'))
        self.assertTrue(rules.matches('build', directory=True))
        self.assertFalse(rules.matches('src/build/out.txt'), 'a leading / anchors at the root')
        self.assertTrue(rules.matches('figures/a/b/plot.png'))
        self.assertTrue(rules.matches('figures/plot.png'))
        self.assertFalse(rules.matches('figures/plot.svg'))
        self.assertTrue(rules.matches('notes1.md'))
        self.assertFalse(rules.matches('notes12.md'))
        self.assertTrue(rules.matches('keep.pdf'), 'negation is not supported, so *.pdf still applies')
        self.assertFalse(sync_merge.ExcludeRules([]))

    def test_excluded_paths_are_never_copied_overwritten_or_deleted(self):
        (self.local / 'paper.tex').write_text('anchor')
        (self.local / 'data' / 'raw').mkdir(parents=True)
        (self.local / 'data' / 'raw' / 'big.csv').write_text('anchor data')
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertTrue((self.cloud / 'data' / 'raw' / 'big.csv').exists())
        rules = ['--exclude=data/raw/', '--exclude=*.pdf']
        (self.local / 'data' / 'raw' / 'big.csv').unlink()
        (self.cloud / 'data' / 'raw' / 'new.csv').write_text('cloud only')
        (self.local / 'draft.pdf').write_text('local pdf')
        (self.cloud / 'draft.pdf').write_text('different cloud pdf')
        (self.local / 'paper.tex').write_text('local edit')
        preview = self.run_merge('--dry-run', '--plan-json', *rules)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertEqual(self.plan(preview)['items'],
                         [{'action': 'upload', 'name': 'paper.tex', 'size': len('local edit')}])
        result = self.run_merge(*rules)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'local edit')
        self.assertEqual((self.cloud / 'data' / 'raw' / 'big.csv').read_text(), 'anchor data')
        self.assertFalse((self.local / 'data' / 'raw' / 'new.csv').exists())
        self.assertEqual((self.cloud / 'draft.pdf').read_text(), 'different cloud pdf')
        self.assertIn('data/raw/big.csv', json.loads(self.state.read_text())['files'],
                      'the anchor of a newly excluded file is kept')
        self.assertNotIn('DELETED', result.stdout)

    def test_root_ignore_file_protects_upload_download_overwrite_and_delete(self):
        (self.local / 'private').mkdir()
        (self.local / 'private' / 'anchor.txt').write_text('preserve cloud copy')
        (self.local / 'cache.bin').write_text('local cache')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'private' / 'anchor.txt').unlink()
        (self.cloud / 'private' / 'new.txt').write_text('cloud only')
        (self.cloud / 'cache.bin').write_text('different cloud cache')
        (self.local / '.pathsyncignore').write_bytes(
            b'\xef\xbb\xbf# local root rules\r\nprivate/\r\n/cache.bin\r\n')
        (self.local / 'app-only.txt').write_text('excluded by app setting')
        (self.local / 'source.py').write_text('keep syncing source')
        before = self.snapshot_everything()
        preview = self.run_merge('--dry-run', '--plan-json', '--exclude=app-only.txt')
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertEqual({item['name'] for item in self.plan(preview)['items']},
                         {'.pathsyncignore', 'source.py'})
        self.assertEqual(self.snapshot_everything(), before)
        for direction in ('merge', 'upload', 'download'):
            result = self.run_merge('--direction', direction, '--exclude=app-only.txt')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((self.cloud / 'private' / 'anchor.txt').read_text(),
                             'preserve cloud copy')
            self.assertFalse((self.local / 'private' / 'new.txt').exists())
            self.assertEqual((self.local / 'cache.bin').read_text(), 'local cache')
            self.assertEqual((self.cloud / 'cache.bin').read_text(), 'different cloud cache')
        self.assertEqual((self.cloud / 'source.py').read_text(), 'keep syncing source')
        self.assertEqual((self.cloud / '.pathsyncignore').read_bytes(),
                         (self.local / '.pathsyncignore').read_bytes())
        self.assertTrue((self.local / '.pathsyncignore').read_bytes().startswith(b'\xef\xbb\xbf'))
        self.assertIn('.pathsyncignore', json.loads(self.state.read_text())['files'])

    def test_root_ignore_rules_reload_and_do_not_apply_to_another_pair(self):
        ignore = self.local / '.pathsyncignore'
        ignore.write_text('first.bin\n')
        (self.local / 'first.bin').write_text('first')
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertFalse((self.cloud / 'first.bin').exists())
        ignore.write_text('second.bin\n')
        (self.local / 'second.bin').write_text('second')
        self.assertEqual(self.run_merge().returncode, 0)
        # Removing an exclusion becomes effective once both rule copies agree.
        self.assertFalse((self.cloud / 'first.bin').exists())
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertTrue((self.cloud / 'first.bin').exists())
        self.assertFalse((self.cloud / 'second.bin').exists())
        other_local, other_cloud = self.root / 'other-local', self.root / 'other-cloud'
        other_local.mkdir()
        other_cloud.mkdir()
        (other_local / 'second.bin').write_text('another pair')
        result = subprocess.run([sys.executable, str(HELPER), str(other_local),
                                 str(other_cloud), str(self.root / 'other-state.json')],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((other_cloud / 'second.bin').read_text(), 'another pair')

    def test_invalid_ignore_file_aborts_before_writing(self):
        ignore = self.local / '.pathsyncignore'
        (self.local / 'source.py').write_text('must not copy')
        for content in (b'\xff\xfe', b'x' * (1024 * 1024 + 1)):
            ignore.write_bytes(content)
            before = self.snapshot_everything()
            for flags in ((), ('--dry-run', '--plan-json')):
                result = self.run_merge(*flags)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('.pathsyncignore', result.stderr)
                self.assertEqual(self.snapshot_everything(), before)
        ignore.unlink()
        external = self.root / 'external-ignore'
        external.write_text('source.py\n')
        ignore.symlink_to(external)
        self.assertEqual(self.run_merge().returncode, 2)
        self.assertFalse((self.cloud / 'source.py').exists())
        ignore.unlink()
        ignore.mkdir()
        self.assertEqual(self.run_merge().returncode, 2)
        self.assertFalse(self.state.exists())

    def test_one_way_helper_reads_root_ignore_and_explicit_rules(self):
        (self.local / '.pathsyncignore').write_text('hidden.bin\n')
        for name in ('hidden.bin', 'app.bin', 'source.py'):
            (self.local / name).write_text(name)
        arguments = [sys.executable, str(HELPER.parent / 'sync_tree.py'),
                     str(self.local), str(self.cloud), '--exclude=app.bin']
        preview = subprocess.run([*arguments, '--dry-run'], capture_output=True,
                                 text=True, timeout=15)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn('copied=2', preview.stdout)
        self.assertEqual(list(self.cloud.iterdir()), [])
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({p.name for p in self.cloud.iterdir()},
                         {'source.py', '.pathsyncignore'})

    def test_cloud_rules_apply_before_first_download_even_when_they_ignore_themselves(self):
        (self.cloud / '.pathsyncignore').write_text('private/\n.pathsyncignore\n')
        (self.cloud / 'private').mkdir()
        (self.cloud / 'private' / 'large.bin').write_text('cloud private file')
        (self.cloud / 'source.py').write_text('source')
        result = self.run_merge('--direction', 'download')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.local / '.pathsyncignore').exists())
        self.assertTrue((self.local / 'source.py').exists())
        self.assertFalse((self.local / 'private').exists())

    def test_conflicting_ignore_files_filter_with_both_rule_sets_before_keep_both(self):
        (self.local / '.pathsyncignore').write_text('local-private/\n')
        (self.cloud / '.pathsyncignore').write_text('cloud-private/\n')
        for root, name in ((self.local, 'local-private'), (self.cloud, 'cloud-private')):
            (root / name).mkdir()
            (root / name / 'data.bin').write_text('private')
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.cloud / 'local-private').exists())
        self.assertFalse((self.local / 'cloud-private').exists())
        self.assertEqual((self.cloud / '.pathsyncignore').read_text(), 'local-private/\n')
        copies = list(self.local.glob('.pathsyncignore (cloud conflict *)'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_text(), 'cloud-private/\n')

    def test_online_only_ignore_file_is_not_downloaded_by_preview(self):
        (self.cloud / '.pathsyncignore').write_text('private/\n')
        (self.cloud / 'source.py').write_text('source')
        before = self.snapshot_everything()
        with self.assertRaisesRegex(OSError, '规则文件仅在线'):
            self.run_in_process('--dry-run', '--plan-json', online=['.pathsyncignore'])
        self.assertEqual(self.snapshot_everything(), before)
        code, output, hydrated = self.run_in_process(online=['.pathsyncignore'])
        self.assertEqual(code, 0, output)
        self.assertEqual([Path(path).name for path in hydrated], ['.pathsyncignore'])
        self.assertTrue((self.local / '.pathsyncignore').exists())

    def run_in_process(self, *extra, online=()):
        """Run main() here so is_dataless can mark chosen cloud files as online-only."""
        online_paths = {str((self.cloud / name).resolve()) for name in online}
        hydrated = []

        def fake_dataless(path):
            return str(Path(path).resolve()) in online_paths and str(Path(path).resolve()) not in hydrated

        def fake_hydrate(path):
            hydrated.append(str(Path(path).resolve()))
            return None

        argv = ['sync_merge.py', str(self.local), str(self.cloud), str(self.state),
                '--exclude-latex', '--conflict-policy', 'keep-both', *extra]
        output = io.StringIO()
        with mock.patch.object(sync_merge, 'is_dataless', side_effect=fake_dataless), \
                mock.patch.object(sync_merge.CloudPrefetch, 'hydrate', side_effect=fake_hydrate), \
                mock.patch.object(sys, 'argv', argv), contextlib.redirect_stdout(output):
            code = sync_merge.main()
        return code, output.getvalue(), hydrated

    def test_preview_reports_online_only_files_without_downloading(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.cloud / 'paper.tex').write_text('cloud edit')
        (self.cloud / 'new.pdf').write_text('new online file')
        before = self.snapshot_everything()
        code, output, hydrated = self.run_in_process(
            '--dry-run', '--plan-json', '--hydrate-online-only', online=['paper.tex', 'new.pdf'])
        self.assertEqual(code, 0, output)
        self.assertEqual(hydrated, [], 'a preview never downloads placeholders')
        self.assertEqual(self.snapshot_everything(), before)
        plan = json.loads(next(line for line in output.splitlines()
                               if line.startswith('PLAN_JSON\t')).split('\t', 1)[1])
        self.assertIn({'action': 'online', 'name': 'paper.tex', 'size': len('cloud edit')}, plan['items'])
        self.assertIn({'action': 'download', 'name': 'new.pdf', 'size': len('new online file'),
                       'online': True}, plan['items'])
        self.assertEqual(plan['counts']['online_only'], 2)

    def test_sync_downloads_needed_online_only_files_first(self):
        (self.local / 'paper.tex').write_text('anchor')
        (self.local / 'untouched.tex').write_text('same')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.cloud / 'paper.tex').write_text('cloud edit')
        code, output, hydrated = self.run_in_process(
            '--hydrate-online-only', online=['paper.tex', 'untouched.tex'])
        self.assertEqual(code, 0, output)
        self.assertEqual([Path(item).name for item in hydrated], ['paper.tex'],
                         'only files the merge must read are downloaded')
        self.assertIn('ONLINE_ONLY\t1', output)
        self.assertLess(output.index('PROGRESS\tPREFETCH\t0\t1'), output.index('PROGRESS\tFILE\tpaper.tex'))
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud edit')

    def test_unique_files_and_one_sided_updates(self):
        (self.local / 'paper.tex').write_text('local v1')
        (self.cloud / 'figure.pdf').write_text('cloud v1')
        (self.local / 'build.aux').write_text('do not sync')
        first = self.run_merge()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'local v1')
        self.assertEqual((self.local / 'figure.pdf').read_text(), 'cloud v1')
        self.assertFalse((self.cloud / 'build.aux').exists())

        (self.cloud / 'figure.pdf').write_text('cloud v2 with new length')
        (self.local / 'paper.tex').write_text('local v2 with new length')
        second = self.run_merge()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual((self.local / 'figure.pdf').read_text(), 'cloud v2 with new length')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'local v2 with new length')
        self.assertIn('uploaded=1 downloaded=1', second.stdout)

    def test_pair_filters_preserve_existing_copies_and_anchors(self):
        for name in ('AGENTS.md', 'CLAUDE.md', '.mcp.json', '.codex/config.toml',
                     '.agents/skills/test/SKILL.md', '.claude/settings.json',
                     '.claude/settings.local.json', 'tmp/build.txt'):
            path = self.local / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        first = self.run_merge('--include-temp')
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertTrue((self.cloud / 'AGENTS.md').exists())
        self.assertTrue((self.cloud / 'tmp/build.txt').exists())
        self.assertFalse((self.cloud / '.claude/settings.local.json').exists())
        filtered = self.run_merge('--skip-codex', '--skip-claude')
        self.assertEqual(filtered.returncode, 0, filtered.stdout + filtered.stderr)
        self.assertTrue((self.cloud / 'AGENTS.md').exists())
        self.assertTrue((self.cloud / 'CLAUDE.md').exists())
        self.assertTrue((self.cloud / 'tmp/build.txt').exists())
        (self.local / 'AGENTS.md').write_text('new instruction')
        still_filtered = self.run_merge('--skip-codex', '--skip-claude')
        self.assertEqual(still_filtered.returncode, 0, still_filtered.stdout + still_filtered.stderr)
        self.assertEqual((self.cloud / 'AGENTS.md').read_text(), 'AGENTS.md')
        resumed = self.run_merge('--include-temp')
        self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
        self.assertEqual((self.cloud / 'AGENTS.md').read_text(), 'new instruction')

    def test_temp_and_agent_filters_on_initial_sync(self):
        for name in ('AGENTS.md', 'CLAUDE.md', '.codex/config.toml',
                     '.claude/settings.json', '.claude/settings.local.json',
                     'tmp/cache.bin', '.tmp/scratch', '.pptx-polish-a/asset.ppt',
                     'paper.tmp', 'paper.tex'):
            path = self.local / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        result = self.run_merge('--skip-codex', '--skip-claude')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.cloud / 'paper.tex').exists())
        for name in ('AGENTS.md', 'CLAUDE.md', '.codex/config.toml',
                     '.claude/settings.json', '.claude/settings.local.json',
                     'tmp/cache.bin', '.tmp/scratch', '.pptx-polish-a/asset.ppt', 'paper.tmp'):
            self.assertFalse((self.cloud / name).exists(), name)

    def test_file_provider_metadata_drift_and_concurrent_edit(self):
        local_file = self.local / 'main.tex'
        cloud_file = self.cloud / 'main.tex'
        local_file.write_text('base')
        cloud_file.write_text('base')
        stamp = 1_790_000_000_750_000_000
        os.utime(local_file, ns=(stamp, stamp))
        os.utime(cloud_file, ns=(stamp, stamp))
        self.assertEqual(self.run_merge(policy='keep-both').returncode, 0)
        rounded = stamp // 1_000_000_000 * 1_000_000_000
        os.utime(cloud_file, ns=(rounded, rounded))
        unchanged = self.run_merge(policy='keep-both')
        self.assertEqual(unchanged.returncode, 0, unchanged.stdout + unchanged.stderr)
        self.assertIn('unchanged=1', unchanged.stdout)
        local_file.write_text('left')
        cloud_file.write_text('rght')
        os.utime(cloud_file, ns=(rounded, rounded))
        conflicting = self.run_merge('--dry-run', policy='keep-both')
        self.assertEqual(conflicting.returncode, 0, conflicting.stdout + conflicting.stderr)
        self.assertIn('WOULD_KEEP_BOTH\tmain.tex', conflicting.stdout)

    def test_unresponsive_file_read_has_deadline(self):
        pipe = self.root / 'unresponsive'
        os.mkfifo(pipe)
        with mock.patch.object(sync_merge, 'FILE_READ_TIMEOUT_SECONDS', 0.1):
            with self.assertRaises(TimeoutError):
                sync_merge.digest(pipe)

    def test_parallel_prefetch_reports_missing_file_without_writing(self):
        names = [f'file-{index}.txt' for index in range(100)]
        for name in names[:-1]:
            (self.cloud / name).write_text(name)
        prefetch = sync_merge.CloudPrefetch(self.cloud, names)
        failures = {name: error for name in names
                    if (error := prefetch.check(name)) is not None}
        prefetch.close()
        self.assertEqual(set(failures), {names[-1]})
        self.assertFalse((self.cloud / names[-1]).exists())

    def test_large_cloud_placeholder_gets_longer_bounded_read(self):
        path = self.cloud / 'video.mp4'
        with path.open('wb') as output:
            output.truncate(200_000_000)
        with mock.patch.object(sync_merge.subprocess, 'run') as run:
            run.return_value.returncode = 0
            self.assertIsNone(sync_merge.CloudPrefetch.hydrate(path))
            self.assertEqual(run.call_args.kwargs['timeout'], 300)

    def test_large_import_copies_before_all_prefetch_results_are_consumed(self):
        for index in range(100):
            (self.cloud / f'file-{index:03}.txt').write_text(str(index))
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        first_copy = result.stdout.index('PROGRESS\tFILE\tfile-000.txt')
        last_prefetch = result.stdout.index('PROGRESS\tPREFETCH\t100\t100')
        self.assertLess(first_copy, last_prefetch)
        self.assertEqual(len(list(self.local.iterdir())), 100)

    def test_large_new_file_does_not_hold_up_small_imports(self):
        with (self.cloud / 'a-large.bin').open('wb') as output:
            output.truncate(5_000_000)
        for index in range(99):
            (self.cloud / f'z-small-{index:03}.txt').write_text(str(index))
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(result.stdout.index('PROGRESS\tFILE\tz-small-000.txt'),
                        result.stdout.index('PROGRESS\tFILE\ta-large.bin'))

    def test_conflict_preserves_both_and_reports_it(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local changed')
        (self.cloud / 'paper.tex').write_text('cloud changed')
        result = self.run_merge()
        self.assertEqual(result.returncode, 2)
        self.assertIn('CONFLICT\tpaper.tex', result.stdout)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local changed')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud changed')
        state = json.loads(self.state.read_text())
        self.assertIn('paper.tex', state['conflicts'])

    def test_resolve_with_local_keeps_verified_backups(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local version')
        (self.cloud / 'paper.tex').write_text('cloud version')
        self.assertEqual(self.run_merge().returncode, 2)

        result = self.run_merge('--resolve', 'paper.tex', '--choice', 'local')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'local version')
        backup = Path(result.stdout.split('backup=', 1)[1].strip())
        self.assertEqual((backup / 'local.tex').read_text(), 'local version')
        self.assertEqual((backup / 'cloud.tex').read_text(), 'cloud version')
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})
        self.assertEqual(self.run_merge().returncode, 0)

    def test_resolve_with_cloud_updates_local(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local version')
        (self.cloud / 'paper.tex').write_text('cloud version')
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', 'paper.tex', '--choice', 'cloud')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud version')

    def test_keep_both_propagates_labeled_cloud_copy(self):
        (self.local / 'chapter.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'chapter.tex').write_text('local version')
        (self.cloud / 'chapter.tex').write_text('cloud version')
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', 'chapter.tex', '--choice', 'both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'chapter.tex').read_text(), 'local version')
        self.assertEqual((self.cloud / 'chapter.tex').read_text(), 'local version')
        copies = list(self.local.glob('chapter (cloud conflict *).tex'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_text(), 'cloud version')
        self.assertEqual((self.cloud / copies[0].name).read_text(), 'cloud version')
        self.assertEqual(json.loads(self.state.read_text())['conflicts']['chapter.tex']['status'], 'preserved')
        self.assertIn('reviews=1', self.run_merge().stdout)

    def test_review_survives_later_sync_until_explicit_acknowledgement(self):
        (self.local / 'paper.tex').write_text('local original')
        (self.cloud / 'paper.tex').write_text('cloud original')
        self.preserve_for_review()
        copy = next(self.local.glob('paper (cloud conflict *).tex'))
        (self.local / 'paper.tex').write_text('manually merged content')
        synced = self.run_merge()
        self.assertEqual(synced.returncode, 0, synced.stdout + synced.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'manually merged content')
        self.assertIn('NEEDS_REVIEW\tpaper.tex', synced.stdout)
        self.assertEqual((self.cloud / copy.name).read_text(), 'cloud original')
        acknowledged = self.run_merge('--acknowledge', 'paper.tex')
        self.assertEqual(acknowledged.returncode, 0, acknowledged.stdout + acknowledged.stderr)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})
        self.assertIn('reviews=0', self.run_merge().stdout)
        self.assertEqual((self.local / copy.name).read_text(), 'cloud original')

    def test_review_never_overwrites_new_divergence(self):
        (self.local / 'paper.tex').write_text('local original')
        (self.cloud / 'paper.tex').write_text('cloud original')
        self.preserve_for_review()
        (self.local / 'paper.tex').write_text('local new')
        (self.cloud / 'paper.tex').write_text('cloud new')
        result = self.run_merge()
        self.assertEqual(result.returncode, 2)
        self.assertIn('FAILED\tpaper.tex', result.stdout)
        self.assertIn('reviews=1', result.stdout)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local new')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud new')
        self.assertEqual(self.run_merge('--acknowledge', 'paper.tex').returncode, 2)

    def test_old_kept_both_state_migrates_to_review_once(self):
        (self.local / 'paper.tex').write_text('local original')
        (self.cloud / 'paper.tex').write_text('cloud original')
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
        old_state = json.loads(self.state.read_text())
        old_state['conflicts'] = {}
        old_state.pop('reviewsInitialized')
        self.state.write_text(json.dumps(old_state))
        migrated = self.run_merge()
        self.assertEqual(migrated.returncode, 0, migrated.stdout + migrated.stderr)
        self.assertIn('reviews=1', migrated.stdout)
        self.assertEqual(json.loads(self.state.read_text())['conflicts']['paper.tex']['status'], 'preserved')
        self.assertEqual(self.run_merge('--acknowledge', 'paper.tex').returncode, 0)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})
        self.assertIn('reviews=0', self.run_merge().stdout)

    def test_keep_both_rejects_sidecar_name_collision_before_writing(self):
        (self.local / 'chapter.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'chapter.tex').write_text('local')
        (self.cloud / 'chapter.tex').write_text('cloud')
        self.assertEqual(self.run_merge().returncode, 2)
        suffix = hashlib.sha256(b'cloud').hexdigest()[:12]
        sidecar = f'chapter (cloud conflict {suffix}).tex'
        (self.local / sidecar).write_text('unrelated file')
        result = self.run_merge('--resolve', 'chapter.tex', '--choice', 'both')
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.cloud / sidecar).exists())
        self.assertEqual((self.local / 'chapter.tex').read_text(), 'local')
        self.assertEqual((self.cloud / 'chapter.tex').read_text(), 'cloud')

    def test_auto_keep_both_collision_leaves_originals_and_pending_state(self):
        (self.local / 'chapter.tex').write_text('local')
        (self.cloud / 'chapter.tex').write_text('cloud')
        suffix = hashlib.sha256(b'cloud').hexdigest()[:12]
        sidecar = f'chapter (cloud conflict {suffix}).tex'
        (self.local / sidecar).write_text('unrelated file')
        result = self.run_merge(policy=None)
        self.assertEqual(result.returncode, 2)
        self.assertIn('FAILED\tchapter.tex', result.stdout)
        self.assertEqual((self.local / 'chapter.tex').read_text(), 'local')
        self.assertEqual((self.cloud / 'chapter.tex').read_text(), 'cloud')
        self.assertIn('chapter.tex', json.loads(self.state.read_text())['conflicts'])

    def test_changed_after_listing_requires_refresh(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local old')
        (self.cloud / 'paper.tex').write_text('cloud old')
        self.assertEqual(self.run_merge().returncode, 2)
        (self.local / 'paper.tex').write_text('local new')
        result = self.run_merge('--resolve', 'paper.tex', '--choice', 'cloud')
        self.assertEqual(result.returncode, 2)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local new')
        self.assertEqual(self.run_merge().returncode, 2)
        self.assertEqual(self.run_merge('--resolve', 'paper.tex', '--choice', 'cloud').returncode, 0)

    def test_directional_runs_do_not_overwrite_divergent_destination(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.cloud / 'paper.tex').write_text('cloud edited')
        result = self.run_merge('--direction', 'upload')
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud edited')
        self.assertIn('skipped=1', result.stdout)
        self.assertNotIn('paper.tex', json.loads(self.state.read_text())['conflicts'])

    def test_directional_upload_of_source_change_succeeds(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('new local content')
        result = self.run_merge('--direction', 'upload')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'new local content')

    def test_first_directional_run_does_not_pick_a_winner(self):
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud')
        result = self.run_merge('--direction', 'download')
        self.assertEqual(result.returncode, 2)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud')

    def test_symlinked_destination_parent_is_not_followed(self):
        (self.local / 'chapter').mkdir()
        (self.local / 'chapter' / 'paper.tex').write_text('safe')
        outside = self.root / 'outside'
        outside.mkdir()
        (self.cloud / 'chapter').symlink_to(outside, target_is_directory=True)
        result = self.run_merge()
        self.assertEqual(result.returncode, 2)
        self.assertFalse((outside / 'paper.tex').exists())
        self.assertIn('FAILED\tchapter/paper.tex', result.stdout)

    def test_first_run_does_not_choose_a_winner_for_divergent_file(self):
        left = self.local / 'same-name.tex'
        right = self.cloud / 'same-name.tex'
        left.write_text('AAAA')
        right.write_text('BBBB')
        timestamp = 1_700_000_000_000_000_000
        os.utime(left, ns=(timestamp, timestamp))
        os.utime(right, ns=(timestamp, timestamp))
        result = self.run_merge()
        self.assertEqual(result.returncode, 2)
        self.assertIn('CONFLICT\tsame-name.tex', result.stdout)
        self.assertEqual(left.read_text(), 'AAAA')
        self.assertEqual(right.read_text(), 'BBBB')

    def test_one_sided_deletion_and_unrelated_addition_follow_same_anchor(self):
        (self.local / 'source.tex').write_text('keep')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'source.tex').unlink()
        (self.cloud / 'extra.bib').write_text('reference')
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertFalse((self.local / 'source.tex').exists())
        self.assertFalse((self.cloud / 'source.tex').exists())
        self.assertEqual((self.local / 'extra.bib').read_text(), 'reference')

    def test_dry_run_does_not_copy_or_write_state(self):
        (self.cloud / 'new.tex').write_text('cloud')
        result = self.run_merge('--dry-run')
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.local / 'new.tex').exists())
        self.assertFalse(self.state.exists())
        self.assertIn('downloaded=1', result.stdout)

    def test_anchor_uses_content_and_one_sided_direction_skips(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.cloud / 'paper.tex').write_text('cloud only')
        upload = self.run_merge('--direction', 'upload')
        self.assertEqual(upload.returncode, 0, upload.stdout + upload.stderr)
        self.assertIn('skipped=1', upload.stdout)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'anchor')
        merged = self.run_merge()
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud only')
        self.assertEqual(json.loads(self.state.read_text())['files']['paper.tex']['anchorHash'],
                         hashlib.sha256(b'cloud only').hexdigest())

    def test_two_metadata_changes_with_same_content_do_not_conflict(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('same new content')
        (self.cloud / 'paper.tex').write_text('same new content')
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('conflicts=0', result.stdout)

    def test_same_size_and_mtime_replacement_still_changes_the_anchor(self):
        local_file = self.local / 'paper.tex'
        cloud_file = self.cloud / 'paper.tex'
        local_file.write_text('AAAA')
        self.assertEqual(self.run_merge().returncode, 0)
        old_mtime = local_file.stat().st_mtime_ns
        replacement = self.local / 'new-paper.tex'
        replacement.write_text('BBBB')
        os.utime(replacement, ns=(old_mtime, old_mtime))
        os.replace(replacement, local_file)
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(cloud_file.read_text(), 'BBBB')

    def test_newest_conflict_backs_up_loser_and_restores_from_history_id(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('new local')
        (self.cloud / 'paper.tex').write_text('new cloud')
        base = 1_800_000_000_000_000_000
        os.utime(self.cloud / 'paper.tex', ns=(base, base))
        os.utime(self.local / 'paper.tex', ns=(base + 1_000_000_000, base + 1_000_000_000))
        result = self.run_merge('--conflict-policy', 'newest')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'new local')
        self.assertIn('newest=1', result.stdout)
        backup_id = re.search(r'BACKUP\tpaper.tex\tside=cloud\tid=([0-9a-f]{32})', result.stdout).group(1)
        backup_dir = self.root / 'state-backups' / backup_id
        self.assertEqual((backup_dir / 'content').read_text(), 'new cloud')
        self.assertEqual(json.loads((backup_dir / 'manifest.json').read_text())['retentionDays'], 15)
        restored = self.run_merge('--restore', backup_id)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'new cloud')
        self.assertIn('reason=restore-overwrite', restored.stdout)

    def test_newest_tied_timestamp_requires_manual_choice(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('new local')
        (self.cloud / 'paper.tex').write_text('new cloud')
        timestamp = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(timestamp, timestamp))
        os.utime(self.cloud / 'paper.tex', ns=(timestamp, timestamp))
        result = self.run_merge('--conflict-policy', 'newest')
        self.assertEqual(result.returncode, 2)
        self.assertIn('修改时间相同', result.stdout)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'new cloud')

    def test_newest_does_not_reverse_explicit_upload_direction(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        (self.cloud / 'paper.tex').write_text('newer cloud edit')
        base = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(base, base))
        os.utime(self.cloud / 'paper.tex', ns=(base + 1_000_000_000, base + 1_000_000_000))
        result = self.run_merge('--direction', 'upload', '--conflict-policy', 'newest')
        self.assertEqual(result.returncode, 2)
        self.assertIn('方向相反', result.stdout)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local edit')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'newer cloud edit')

    def test_manual_pending_conflict_can_choose_newer_date(self):
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud')
        base = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(base, base))
        os.utime(self.cloud / 'paper.tex', ns=(base + 1_000_000_000, base + 1_000_000_000))
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', 'paper.tex', '--choice', 'newest')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud')
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})

    def test_preserved_review_can_choose_newer_current_date(self):
        (self.local / 'paper.tex').write_text('local')
        (self.cloud / 'paper.tex').write_text('cloud newer')
        base = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(base, base))
        os.utime(self.cloud / 'paper.tex', ns=(base + 1_000_000_000, base + 1_000_000_000))
        self.preserve_for_review()
        self.assertEqual((self.local / 'paper.tex').read_text(), 'local')
        result = self.run_merge('--review-newest', 'paper.tex')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud newer')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud newer')
        self.assertIn('reason=review-newest-overwrite', result.stdout)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})

    def test_newer_main_edited_after_preservation_can_finish_review(self):
        (self.local / 'paper.tex').write_text('local original')
        (self.cloud / 'paper.tex').write_text('cloud original')
        base = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(base, base))
        os.utime(self.cloud / 'paper.tex', ns=(base - 1_000_000_000,
                                               base - 1_000_000_000))
        self.preserve_for_review()
        state = json.loads(self.state.read_text())
        sidecar = state['conflicts']['paper.tex']['sidecar']
        (self.local / 'paper.tex').write_text('edited after preservation')
        os.utime(self.local / 'paper.tex', ns=(base + 1_000_000_000,
                                               base + 1_000_000_000))
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'edited after preservation')
        self.assertIn('paper.tex', json.loads(self.state.read_text())['conflicts'])
        result = self.run_merge('--review-newest', 'paper.tex')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('side=local', result.stdout)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'edited after preservation')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'edited after preservation')
        self.assertEqual((self.local / sidecar).read_text(), 'cloud original')
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})

    def test_newer_preserved_copy_replaces_later_edited_main_with_backups(self):
        (self.local / 'paper.tex').write_text('main original')
        (self.cloud / 'paper.tex').write_text('copy original')
        base = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(base, base))
        os.utime(self.cloud / 'paper.tex', ns=(base - 1_000_000_000,
                                               base - 1_000_000_000))
        self.preserve_for_review()
        sidecar = json.loads(self.state.read_text())['conflicts']['paper.tex']['sidecar']
        for root in (self.local, self.cloud):
            (root / 'paper.tex').write_text('main edited later')
            os.utime(root / 'paper.tex', ns=(base + 1_000_000_000,
                                             base + 1_000_000_000))
            (root / sidecar).write_text('copy edited latest')
            os.utime(root / sidecar, ns=(base + 2_000_000_000,
                                          base + 2_000_000_000))
        result = self.run_merge('--review-newest', 'paper.tex')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'copy edited latest')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'copy edited latest')
        self.assertEqual((self.local / sidecar).read_text(), 'copy edited latest')
        self.assertEqual(result.stdout.count('reason=review-newest-overwrite'), 2)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})

    def test_preserved_versions_must_agree_across_roots_before_date_choice(self):
        (self.local / 'paper.tex').write_text('main')
        (self.cloud / 'paper.tex').write_text('copy')
        self.preserve_for_review()
        main_before = (self.local / 'paper.tex').read_text()
        sidecar = json.loads(self.state.read_text())['conflicts']['paper.tex']['sidecar']
        (self.cloud / sidecar).write_text('different copy')
        result = self.run_merge('--review-newest', 'paper.tex')
        self.assertEqual(result.returncode, 2)
        self.assertIn('保留副本两侧已有不同内容', result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), main_before)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), main_before)
        self.assertIn('paper.tex', json.loads(self.state.read_text())['conflicts'])

    def test_one_sided_main_update_resolves_in_same_action(self):
        (self.local / 'paper.tex').write_text('main')
        (self.cloud / 'paper.tex').write_text('copy')
        base = 1_800_000_000_000_000_000
        os.utime(self.local / 'paper.tex', ns=(base, base))
        os.utime(self.cloud / 'paper.tex', ns=(base - 1_000_000_000,
                                               base - 1_000_000_000))
        self.preserve_for_review()
        (self.local / 'paper.tex').write_text('new local edit')
        os.utime(self.local / 'paper.tex', ns=(base + 1_000_000_000,
                                               base + 1_000_000_000))
        result = self.run_merge('--review-newest', 'paper.tex')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'new local edit')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'new local edit')
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        self.assertEqual((self.root / 'state-backups' / backup_id / 'content').read_text(), 'main')
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})

    def test_two_new_main_versions_remain_pending_after_preservation(self):
        (self.local / 'paper.tex').write_text('main')
        (self.cloud / 'paper.tex').write_text('copy')
        self.preserve_for_review()
        (self.local / 'paper.tex').write_text('new local edit')
        (self.cloud / 'paper.tex').write_text('new cloud edit')
        result = self.run_merge('--review-newest', 'paper.tex')
        self.assertEqual(result.returncode, 2)
        self.assertIn('两侧都相对共同版本发生变化', result.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'new local edit')
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'new cloud edit')
        self.assertIn('paper.tex', json.loads(self.state.read_text())['conflicts'])

    def test_one_sided_update_has_recoverable_overwrite_backup(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('updated')
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('backups=1', result.stdout)
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        self.assertEqual((self.root / 'state-backups' / backup_id / 'content').read_text(), 'anchor')

    def test_one_sided_deletion_propagates_with_backup_and_keeps_absent_anchor(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DELETED\tpaper.tex\tside=cloud', result.stdout)
        self.assertFalse((self.cloud / 'paper.tex').exists())
        absent = json.loads(self.state.read_text())['files']['paper.tex']
        self.assertIsNone(absent['local'])
        self.assertIsNone(absent['cloud'])
        self.assertIsNone(absent['anchorHash'])
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        self.assertEqual((self.root / 'state-backups' / backup_id / 'content').read_text(), 'anchor')
        restored = self.run_merge('--restore', backup_id)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'anchor')

    def test_cloud_deletion_follows_direction_and_backs_up_local_file(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.cloud / 'paper.tex').unlink()
        skipped = self.run_merge('--direction', 'upload')
        self.assertEqual(skipped.returncode, 0, skipped.stdout + skipped.stderr)
        self.assertTrue((self.local / 'paper.tex').exists())
        self.assertFalse((self.cloud / 'paper.tex').exists())
        preview = self.run_merge('--direction', 'download', '--dry-run')
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn('WOULD_DELETE\tpaper.tex\tside=local', preview.stdout)
        self.assertTrue((self.local / 'paper.tex').exists())
        result = self.run_merge('--direction', 'download')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DELETED\tpaper.tex\tside=local', result.stdout)
        self.assertFalse((self.local / 'paper.tex').exists())
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        self.assertEqual((self.root / 'state-backups' / backup_id / 'content').read_text(),
                         'anchor')

    def test_legacy_missing_side_cache_cannot_skip_anchor_deletion(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        state = json.loads(self.state.read_text())
        record = state['files']['paper.tex']
        record['local'] = None
        record['localCtime'] = None
        record['missingSide'] = 'local'
        self.state.write_text(json.dumps(state))
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DELETED\tpaper.tex\tside=cloud', result.stdout)
        self.assertFalse((self.cloud / 'paper.tex').exists())
        self.assertNotIn('missingSide', json.loads(self.state.read_text())['files']['paper.tex'])

    def test_delete_edit_is_conflict_and_manual_choice_can_restore(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        (self.cloud / 'paper.tex').write_text('cloud edit')
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 2)
        self.assertIn('CONFLICT\tpaper.tex', result.stdout)
        self.assertFalse((self.local / 'paper.tex').exists())
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud edit')
        resolved = self.run_merge('--resolve', 'paper.tex', '--choice', 'cloud')
        self.assertEqual(resolved.returncode, 0, resolved.stdout + resolved.stderr)
        self.assertEqual((self.local / 'paper.tex').read_text(), 'cloud edit')

    def test_delete_edit_choice_can_delete_after_backup(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        (self.cloud / 'paper.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', 'paper.tex', '--choice', 'local')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.cloud / 'paper.tex').exists())
        self.assertEqual(json.loads(self.state.read_text())['files']['paper.tex']['anchorHash'], None)
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        self.assertEqual((self.root / 'state-backups' / backup_id / 'content').read_text(), 'cloud edit')

    def test_unavailable_root_does_not_turn_missing_path_into_deletion(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        hidden_cloud = self.root / 'cloud-temporarily-unavailable'
        self.cloud.rename(hidden_cloud)
        try:
            result = self.run_merge()
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('目录扫描有错误', result.stdout)
            self.assertEqual((hidden_cloud / 'paper.tex').read_text(), 'anchor')
            self.assertEqual(json.loads(self.state.read_text())['files']['paper.tex']['anchorHash'],
                             hashlib.sha256(b'anchor').hexdigest())
        finally:
            hidden_cloud.rename(self.cloud)

    def test_delete_edit_conflict_remains_pending_across_runs(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        anchor = json.loads(self.state.read_text())['files']['paper.tex']['anchorHash']
        (self.local / 'paper.tex').unlink()
        (self.cloud / 'paper.tex').write_text('cloud edit')
        for _ in range(2):
            result = self.run_merge()
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('CONFLICT\tpaper.tex', result.stdout)
            state = json.loads(self.state.read_text())
            self.assertEqual(state['files']['paper.tex']['anchorHash'], anchor)
            self.assertIn('paper.tex', state['conflicts'])
            self.assertFalse((self.local / 'paper.tex').exists())
            self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud edit')

    def test_default_policy_does_not_hide_delete_edit_conflict(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        (self.cloud / 'paper.tex').write_text('cloud edit')
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('CONFLICT\tpaper.tex', result.stdout)
        self.assertFalse((self.local / 'paper.tex').exists())
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud edit')

    def test_newest_policy_does_not_date_a_deletion_it_cannot_observe(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        (self.cloud / 'paper.tex').write_text('cloud edit')
        result = self.run_merge(policy='newest')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('CONFLICT\tpaper.tex', result.stdout)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud edit')

    def test_both_sides_deleted_accepts_absent_anchor(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').unlink()
        (self.cloud / 'paper.tex').unlink()
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state.read_text())['files']['paper.tex']['anchorHash'], None)

    def test_directory_delete_and_child_edit_blocks_entire_subtree(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'edited.tex').write_text('base edit')
        (chapter / 'sibling.tex').write_text('base sibling')
        (self.local / 'unrelated.tex').write_text('first')
        self.assertEqual(self.run_merge().returncode, 0)
        state_before = json.loads(self.state.read_text())
        shutil.rmtree(chapter)
        (self.cloud / 'chapter' / 'edited.tex').write_text('cloud edit')
        (self.local / 'unrelated.tex').write_text('second')

        for _ in range(2):
            result = self.run_merge(policy='newest')
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('CONFLICT\tchapter\t目录删除与内部修改', result.stdout)
            self.assertFalse(chapter.exists())
            self.assertEqual((self.cloud / 'chapter' / 'edited.tex').read_text(), 'cloud edit')
            self.assertEqual((self.cloud / 'chapter' / 'sibling.tex').read_text(), 'base sibling')
            state = json.loads(self.state.read_text())
            self.assertEqual(state['conflicts']['chapter']['kind'], 'tree')
            self.assertEqual(state['conflicts']['chapter']['deletedSide'], 'local')
            for name in ('chapter/edited.tex', 'chapter/sibling.tex'):
                self.assertEqual(state['files'][name]['anchorHash'],
                                 state_before['files'][name]['anchorHash'])
        self.assertEqual((self.cloud / 'unrelated.tex').read_text(), 'second')
        (self.cloud / 'chapter' / 'sibling.tex').write_text('later cloud edit')
        later = self.run_merge()
        self.assertEqual(later.returncode, 2, later.stdout + later.stderr)
        self.assertFalse(chapter.exists())
        self.assertEqual((self.cloud / 'chapter' / 'sibling.tex').read_text(), 'later cloud edit')

    def test_directory_conflict_clears_after_manual_tree_merge(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'edited.tex').write_text('base')
        (chapter / 'sibling.tex').write_text('sibling')
        self.assertEqual(self.run_merge().returncode, 0)
        shutil.rmtree(chapter)
        (self.cloud / 'chapter' / 'edited.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        shutil.copytree(self.cloud / 'chapter', chapter)
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('chapter', json.loads(self.state.read_text())['conflicts'])
        self.assertEqual(json.loads(self.state.read_text())['files']['chapter/edited.tex']['anchorHash'],
                         hashlib.sha256(b'cloud edit').hexdigest())

    def test_directory_conflict_clears_when_edit_is_reverted(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'edited.tex').write_text('base')
        (chapter / 'sibling.tex').write_text('sibling')
        self.assertEqual(self.run_merge().returncode, 0)
        shutil.rmtree(chapter)
        (self.cloud / 'chapter' / 'edited.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        (self.cloud / 'chapter' / 'edited.tex').write_text('base')
        result = self.run_merge()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('chapter', json.loads(self.state.read_text())['conflicts'])
        self.assertFalse((self.cloud / 'chapter' / 'edited.tex').exists())
        self.assertFalse((self.cloud / 'chapter' / 'sibling.tex').exists())

    def test_directory_conflict_rejects_file_level_resolution(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'edited.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        shutil.rmtree(chapter)
        (self.cloud / 'chapter' / 'edited.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', 'chapter', '--choice', 'local')
        self.assertEqual(result.returncode, 2)
        self.assertIn('目录级冲突', result.stderr)
        self.assertEqual((self.cloud / 'chapter' / 'edited.tex').read_text(), 'cloud edit')

    def test_cloud_directory_delete_and_local_new_child_blocks_subtree(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'old.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        shutil.rmtree(self.cloud / 'chapter')
        (chapter / 'new.tex').write_text('new local file')
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse((self.cloud / 'chapter').exists())
        self.assertEqual((chapter / 'old.tex').read_text(), 'anchor')
        self.assertEqual((chapter / 'new.tex').read_text(), 'new local file')
        record = json.loads(self.state.read_text())['conflicts']['chapter']
        self.assertEqual(record['kind'], 'tree')
        self.assertEqual(record['deletedSide'], 'cloud')

    def test_new_empty_subdirectory_is_treated_as_tree_change(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'old.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        shutil.rmtree(chapter)
        (self.cloud / 'chapter' / 'new-empty-folder').mkdir()
        result = self.run_merge()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('CONFLICT\tchapter', result.stdout)
        self.assertEqual((self.cloud / 'chapter' / 'old.tex').read_text(), 'anchor')

    def test_directory_delete_with_legacy_unknown_anchor_is_conservative(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'edited.tex').write_text('base')
        (chapter / 'sibling.tex').write_text('sibling')
        self.assertEqual(self.run_merge().returncode, 0)
        state = json.loads(self.state.read_text())
        for name in ('chapter/edited.tex', 'chapter/sibling.tex'):
            state['files'][name].pop('anchorHash')
        self.state.write_text(json.dumps(state))
        shutil.rmtree(chapter)
        (self.cloud / 'chapter' / 'edited.tex').write_text('cloud edit')
        result = self.run_merge()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('CONFLICT\tchapter', result.stdout)
        self.assertEqual((self.cloud / 'chapter' / 'sibling.tex').read_text(), 'sibling')

    def test_existing_child_conflict_cannot_bypass_tree_barrier(self):
        chapter = self.local / 'chapter'
        chapter.mkdir()
        (chapter / 'edited.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (chapter / 'edited.tex').write_text('local edit')
        (self.cloud / 'chapter' / 'edited.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        shutil.rmtree(chapter)
        self.assertEqual(self.run_merge().returncode, 2)
        result = self.run_merge('--resolve', 'chapter/edited.tex', '--choice', 'cloud')
        self.assertEqual(result.returncode, 2)
        self.assertIn('上级目录', result.stderr)
        self.assertFalse(chapter.exists())
        self.assertEqual((self.cloud / 'chapter' / 'edited.tex').read_text(), 'cloud edit')

    def test_interrupted_keep_both_recovery_finishes_without_review(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        (self.cloud / 'paper.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        state = json.loads(self.state.read_text())
        record = state['conflicts']['paper.tex']
        sidecar = f'paper (cloud conflict {record["cloudHash"][:12]}).tex'
        record.update({'status': 'preserving', 'primary': 'local', 'sidecar': sidecar})
        self.state.write_text(json.dumps(state))
        (self.local / sidecar).write_text('cloud edit')
        (self.cloud / sidecar).write_text('cloud edit')
        (self.cloud / 'paper.tex').write_text('local edit')
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(state['conflicts'], {})
        self.assertIn(sidecar, state['files'])
        self.assertNotIn('NEEDS_REVIEW', result.stdout)

    def test_interrupted_keep_both_cannot_disappear_without_sidecar(self):
        (self.local / 'paper.tex').write_text('base')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('local edit')
        (self.cloud / 'paper.tex').write_text('cloud edit')
        self.assertEqual(self.run_merge().returncode, 2)
        state = json.loads(self.state.read_text())
        record = state['conflicts']['paper.tex']
        record.update({'status': 'preserving', 'primary': 'local',
                       'sidecar': f'paper (cloud conflict {record["cloudHash"][:12]}).tex'})
        self.state.write_text(json.dumps(state))
        (self.cloud / 'paper.tex').write_text('local edit')
        result = self.run_merge(policy='keep-both')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('中断的冲突保留尚未完成', result.stdout)
        self.assertEqual(json.loads(self.state.read_text())['conflicts']['paper.tex']['status'],
                         'preserving')

    def test_retention_prunes_expired_backup_on_sync(self):
        (self.local / 'paper.tex').write_text('anchor')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'paper.tex').write_text('updated')
        result = self.run_merge()
        backup_id = re.search(r'id=([0-9a-f]{32})', result.stdout).group(1)
        directory = self.root / 'state-backups' / backup_id
        metadata = json.loads((directory / 'manifest.json').read_text())
        old = datetime.now(timezone.utc) - timedelta(days=16)
        metadata['createdAt'] = old.isoformat()
        metadata['createdAtEpoch'] = old.timestamp()
        (directory / 'manifest.json').write_text(json.dumps(metadata))
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertFalse(directory.exists())


if __name__ == '__main__':
    unittest.main()
