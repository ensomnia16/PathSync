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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
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
        self.assertEqual(self.run_merge(policy=None).returncode, 0)
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

    def test_interrupted_keep_both_recovery_preserves_review(self):
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
        self.assertEqual(state['conflicts']['paper.tex']['status'], 'preserved')
        self.assertEqual(state['conflicts']['paper.tex']['sidecar'], sidecar)
        self.assertIn('NEEDS_REVIEW\tpaper.tex', result.stdout)

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
