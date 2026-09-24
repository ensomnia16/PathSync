import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'sync_merge.py'


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
        record = json.loads(self.state.read_text())['conflicts']['paper.tex']
        self.assertEqual(record['status'], 'preserved')
        self.assertEqual(record['sidecar'], copies[0].name)
        again = self.run_merge(policy='keep-both')
        self.assertEqual(again.returncode, 0)
        self.assertIn('reviews=1', again.stdout)
        self.assertNotIn('KEPT_BOTH\t', again.stdout)
        self.assertEqual(len(list(self.local.glob('paper (* conflict *).tex'))), 1)

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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
        copy = next(self.local.glob('paper (cloud conflict *).tex'))
        (self.local / 'paper.tex').write_text('manually merged content')
        synced = self.run_merge(policy=None)
        self.assertEqual(synced.returncode, 0, synced.stdout + synced.stderr)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'manually merged content')
        self.assertIn('NEEDS_REVIEW\tpaper.tex', synced.stdout)
        self.assertEqual((self.cloud / copy.name).read_text(), 'cloud original')
        acknowledged = self.run_merge('--acknowledge', 'paper.tex')
        self.assertEqual(acknowledged.returncode, 0, acknowledged.stdout + acknowledged.stderr)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})
        self.assertIn('reviews=0', self.run_merge(policy=None).stdout)
        self.assertEqual((self.local / copy.name).read_text(), 'cloud original')

    def test_review_never_overwrites_new_divergence(self):
        (self.local / 'paper.tex').write_text('local original')
        (self.cloud / 'paper.tex').write_text('cloud original')
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
        (self.local / 'paper.tex').write_text('local new')
        (self.cloud / 'paper.tex').write_text('cloud new')
        result = self.run_merge(policy=None)
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
        migrated = self.run_merge(policy=None)
        self.assertEqual(migrated.returncode, 0, migrated.stdout + migrated.stderr)
        self.assertIn('reviews=1', migrated.stdout)
        self.assertEqual(json.loads(self.state.read_text())['conflicts']['paper.tex']['status'], 'preserved')
        self.assertEqual(self.run_merge('--acknowledge', 'paper.tex').returncode, 0)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {})
        self.assertIn('reviews=0', self.run_merge(policy=None).stdout)

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
        self.assertEqual(result.returncode, 2)
        self.assertEqual((self.cloud / 'paper.tex').read_text(), 'cloud edited')
        self.assertIn('paper.tex', json.loads(self.state.read_text())['conflicts'])

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

    def test_missing_file_is_restored_without_deleting_other_files(self):
        (self.local / 'source.tex').write_text('keep')
        self.assertEqual(self.run_merge().returncode, 0)
        (self.local / 'source.tex').unlink()
        (self.cloud / 'extra.bib').write_text('reference')
        self.assertEqual(self.run_merge().returncode, 0)
        self.assertEqual((self.local / 'source.tex').read_text(), 'keep')
        self.assertEqual((self.local / 'extra.bib').read_text(), 'reference')

    def test_dry_run_does_not_copy_or_write_state(self):
        (self.cloud / 'new.tex').write_text('cloud')
        result = self.run_merge('--dry-run')
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.local / 'new.tex').exists())
        self.assertFalse(self.state.exists())
        self.assertIn('downloaded=1', result.stdout)


if __name__ == '__main__':
    unittest.main()
