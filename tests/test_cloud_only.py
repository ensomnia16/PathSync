"""Cloud-only policy and local-release checks against disposable fixture trees."""

import json
import contextlib
import io
import mmap
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HELPER = Path(__file__).resolve().parents[1] / 'sync_merge.py'
sys.path.insert(0, str(HELPER.parent))
import cloud_only
import sync_merge


class CloudOnlyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # Keep lexical fixture arguments identical to the roots stored by the
        # legacy resolving sync path, including macOS's /var -> /private/var.
        self.root = Path(self.temporary.name).resolve()
        self.local = self.root / 'local'
        self.cloud = self.root / 'cloud'
        self.state = self.root / 'state.json'
        self.local.mkdir()
        self.cloud.mkdir()

    def write(self, root, name, content='fixture content'):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def run_merge(self, *extra, local=None, cloud=None):
        # A fake HOME also makes CloudStorage guard fixtures independent of the
        # real user's home. All operands remain inside TemporaryDirectory.
        environment = {**os.environ, 'HOME': str(self.root)}
        return subprocess.run(
            [sys.executable, str(HELPER), str(local or self.local), str(cloud or self.cloud),
             str(self.state), '--shared-excludes', '--conflict-policy', 'ask', *extra],
            capture_output=True, text=True, timeout=20, env=environment)

    def successful(self, *extra, **kwargs):
        result = self.run_merge(*extra, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshot(self, root):
        result = {}
        for path in sorted(root.rglob('*')):
            info = path.lstat()
            name = path.relative_to(root).as_posix()
            if stat.S_ISLNK(info.st_mode):
                value = ('link', os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                value = ('directory',)
            elif not info.st_mode & 0o444:
                value = ('unreadable file', info.st_size)
            else:
                value = ('file', path.read_bytes())
            result[name] = (value, stat.S_IMODE(info.st_mode))
        return result

    def seed_pair(self):
        self.write(self.local, 'data/result.json', '{"result": 7}')
        self.write(self.local, 'data/.hidden/evidence.txt', 'hidden evidence')
        (self.local / 'data/empty').mkdir()
        shutil.copytree(self.local / 'data', self.cloud / 'data')
        self.write(self.local, 'data-other/report.txt', 'unrelated data')
        self.successful()

    def release_direct(self):
        local, cloud = self.local.resolve(), self.cloud.resolve()
        files, conflicts = sync_merge.load_state(self.state, local, cloud)
        with contextlib.redirect_stdout(io.StringIO()):
            return cloud_only.release_local(local, cloud, self.state, files, conflicts,
                                            'data', ('data',), sync_merge.save_state)

    def assert_release_rejected(self, *extra, relative='data'):
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        state = self.state.read_bytes() if self.state.exists() else None
        result = self.run_merge('--cloud-only=data', '--release-local=' + relative, *extra)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
        self.assertEqual(self.state.read_bytes() if self.state.exists() else None, state)
        return result

    def test_cloud_only_skips_both_sides_and_preview_does_not_write(self):
        self.seed_pair()
        # Existing anchors must not turn an intentional absent local copy into
        # cloud deletion, nor import cloud changes or upload local changes.
        (self.local / 'data/result.json').unlink()
        self.write(self.cloud, 'data/new-cloud.bin', 'cloud only')
        self.write(self.local, 'data/new-local.bin', 'local only')
        self.write(self.local, 'report.txt', 'continue outside cloud-only')
        before = self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()
        preview = self.successful('--cloud-only=data', '--dry-run', '--plan-json')
        plan = json.loads(next(line.split('\t', 1)[1] for line in preview.stdout.splitlines()
                               if line.startswith('PLAN_JSON\t')))
        self.assertEqual({item['name'] for item in plan['items']}, {'report.txt'})
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()), before)
        self.assertFalse((self.root / 'state.json.cloud-only-history').exists())
        cloud_before = self.snapshot(self.cloud / 'data')
        local_before = self.snapshot(self.local / 'data')
        self.successful('--cloud-only=data')
        self.assertEqual(self.snapshot(self.cloud / 'data'), cloud_before)
        self.assertEqual(self.snapshot(self.local / 'data'), local_before)
        self.assertEqual((self.cloud / 'report.txt').read_text(), 'continue outside cloud-only')
        state = json.loads(self.state.read_text())
        self.assertFalse(any(name == 'data' or name.startswith('data/') for name in state['files']))
        self.assertIn('data-other/report.txt', state['files'])

    def test_multiple_cloud_only_paths_and_exact_file_keep_siblings_visible(self):
        self.write(self.cloud, 'models/weights.bin', 'large model')
        self.write(self.cloud, 'archive/item.txt', 'large archive')
        self.write(self.cloud, 'models/readme.txt', 'model description')
        self.write(self.cloud, 'archive-other/report.txt', 'not the archive prefix')
        self.successful('--cloud-only=models/weights.bin', '--cloud-only=archive')
        self.assertFalse((self.local / 'models/weights.bin').exists())
        self.assertFalse((self.local / 'archive').exists())
        self.assertEqual((self.local / 'models/readme.txt').read_text(), 'model description')
        self.assertEqual((self.local / 'archive-other/report.txt').read_text(), 'not the archive prefix')

    def test_successful_release_checks_hidden_files_allows_cloud_extras_and_keeps_cloud(self):
        self.seed_pair()
        self.write(self.cloud, 'data/cloud-extra.txt', 'already present in cloud')
        # Provider timestamps may differ although bytes agree.
        os.utime(self.cloud / 'data/result.json', ns=(1_000_000_000, 1_000_000_000))
        cloud_before = self.snapshot(self.cloud)
        state_before = json.loads(self.state.read_text())
        self.successful('--cloud-only=data', '--release-local=data')
        self.assertFalse((self.local / 'data').exists())
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        state = json.loads(self.state.read_text())
        self.assertFalse(any(name == 'data' or name.startswith('data/') for name in state['files']))
        self.assertEqual(state['files']['data-other/report.txt'], state_before['files']['data-other/report.txt'])
        histories = list((self.root / 'state.json.cloud-only-history').glob('*.json'))
        self.assertTrue(histories, 'cleared anchor metadata must remain recoverable')
        self.assertTrue(any('data/result.json' in path.read_text() for path in histories))

    def test_successful_single_file_release_does_not_remove_parent_or_sibling(self):
        self.write(self.local, 'models/weights.bin', 'exact copy')
        self.write(self.local, 'models/readme.txt', 'keep here')
        self.successful()
        cloud_before = self.snapshot(self.cloud)
        self.successful('--cloud-only=models/weights.bin', '--release-local=models/weights.bin')
        self.assertFalse((self.local / 'models/weights.bin').exists())
        self.assertEqual((self.local / 'models/readme.txt').read_text(), 'keep here')
        self.assertEqual(self.snapshot(self.cloud), cloud_before)

    def test_release_refuses_unuploaded_or_different_or_missing_cloud_content(self):
        self.seed_pair()
        self.write(self.local, 'data/not-uploaded.txt', 'only local')
        self.assert_release_rejected()
        (self.local / 'data/not-uploaded.txt').unlink()
        self.write(self.local, 'data/result.json', '{"result": 8}')
        self.assert_release_rejected()
        self.write(self.local, 'data/result.json', '{"result": 7}')
        (self.cloud / 'data/.hidden/evidence.txt').unlink()
        self.assert_release_rejected()

    def test_release_refuses_type_difference_and_missing_cloud_directory(self):
        self.seed_pair()
        (self.cloud / 'data/result.json').unlink()
        (self.cloud / 'data/result.json').mkdir()
        self.assert_release_rejected()
        shutil.rmtree(self.cloud / 'data')
        self.assert_release_rejected()

    def test_release_refuses_unreadable_content(self):
        self.seed_pair()
        hidden = self.cloud / 'data/.hidden/evidence.txt'
        original_mode = stat.S_IMODE(hidden.stat().st_mode)
        hidden.chmod(0)
        try:
            self.assert_release_rejected()
        finally:
            hidden.chmod(original_mode)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS lsof occupancy check')
    def test_open_writer_handle_refuses_staged_release_and_rolls_back(self):
        self.seed_pair()
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        with (self.local / 'data/result.json').open('r+b'):
            with self.assertRaises(OSError):
                self.release_direct()
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
        journals = list(self.root.glob('.pathsync-local-release-*/release.json'))
        self.assertEqual(len(journals), 1)
        self.assertEqual(json.loads(journals[0].read_text())['status'], 'rolled_back')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS lsof mapping check')
    def test_writable_memory_mapping_refuses_release_and_preserves_data(self):
        self.seed_pair()
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        with (self.local / 'data/result.json').open('r+b') as file:
            mapping = mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_WRITE)
        try:
            with self.assertRaises(OSError):
                self.release_direct()
        finally:
            mapping.close()
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS resource forks')
    def test_release_refuses_a_local_resource_fork_missing_from_the_cloud_copy(self):
        self.seed_pair()
        target = self.local / 'data/result.json'
        result = subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.ResourceFork',
                                 'unique resource fork fixture', str(target)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        before = subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.ResourceFork', str(target)])
        self.assert_release_rejected()
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.apple.ResourceFork', str(target)]), before)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS xattrs')
    def test_release_refuses_unique_local_extended_attributes(self):
        self.seed_pair()
        target = self.local / 'data/result.json'
        result = subprocess.run(['/usr/bin/xattr', '-w', 'com.pathsync.test-evidence',
                                 'unique metadata fixture', str(target)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        before = subprocess.check_output(['/usr/bin/xattr', '-p', 'com.pathsync.test-evidence', str(target)])
        self.assert_release_rejected()
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.pathsync.test-evidence', str(target)]), before)

    def test_release_accepts_private_provider_directories_and_disposable_finder_cache(self):
        self.seed_pair()
        (self.local / 'data').chmod(0o755)
        (self.cloud / 'data').chmod(0o700)
        self.write(self.local, 'data/.DS_Store', 'rebuildable Finder cache')
        self.successful('--cloud-only=data', '--release-local=data')
        self.assertFalse((self.local / 'data').exists())
        self.assertTrue((self.cloud / 'data/result.json').exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS per-device metadata')
    def test_release_accepts_device_last_use_attribute_differences(self):
        self.seed_pair()
        result = subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.lastuseddate#PS',
                                 'local last use', str(self.local / 'data/result.json')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.successful('--cloud-only=data', '--release-local=data')
        self.assertFalse((self.local / 'data').exists())

    def test_release_refuses_executable_bit_differences_despite_equal_file_bytes(self):
        self.seed_pair()
        (self.local / 'data/result.json').chmod(0o755)
        (self.cloud / 'data/result.json').chmod(0o644)
        self.assert_release_rejected()

    def test_release_refuses_local_hardlink_aliases_inside_or_outside_the_working_root(self):
        self.seed_pair()
        source = self.local / 'data/result.json'
        for alias in (self.local / 'outside-selection-alias.json', self.root / 'outside-root-alias.json'):
            with self.subTest(alias=alias.name):
                os.link(source, alias)
                try:
                    self.assertEqual(source.stat().st_nlink, 2)
                    self.assert_release_rejected()
                    self.assertEqual(source.read_text(), '{"result": 7}')
                    self.assertEqual(alias.read_text(), '{"result": 7}')
                    self.assertEqual(source.stat().st_nlink, 2)
                finally:
                    alias.unlink()

    def test_cloud_extra_hardlink_does_not_block_a_single_link_local_release(self):
        self.seed_pair()
        os.link(self.cloud / 'data/result.json', self.cloud / 'data/cloud-extra-alias.json')
        self.assertEqual((self.local / 'data/result.json').stat().st_nlink, 1)
        cloud_before = self.snapshot(self.cloud)
        self.successful('--cloud-only=data', '--release-local=data')
        self.assertFalse((self.local / 'data').exists())
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        self.assertEqual((self.cloud / 'data/result.json').stat().st_nlink, 2)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS lsof protocol')
    def test_empty_lsof_success_output_is_not_accepted_as_idle(self):
        # Only rc=1 with no stdout/stderr is the lsof no-match contract. An
        # empty rc=0 is ambiguous, not evidence that a staged tree is unused.
        payload = self.root / 'payload'
        payload.mkdir()
        response = subprocess.CompletedProcess(['lsof'], 0, stdout=b'', stderr=b'')
        with mock.patch.object(cloud_only.subprocess, 'run', return_value=response) as process:
            with self.assertRaisesRegex(OSError, '占用核查不完整'):
                cloud_only.ensure_not_in_use(payload)
            process.assert_called_once()
        idle = subprocess.CompletedProcess(['lsof'], 1, stdout=b'', stderr=b'')
        with mock.patch.object(cloud_only.subprocess, 'run', return_value=idle):
            cloud_only.ensure_not_in_use(payload)

    def test_release_refuses_any_symbolic_link_without_following_it(self):
        self.seed_pair()
        outside = self.write(self.root, 'outside/unique.txt', 'must remain outside')
        (self.local / 'data/linked.txt').symlink_to(outside)
        self.assert_release_rejected()
        (self.local / 'data/linked.txt').unlink()
        # A cloud-only extra is allowed when regular, not when it is a link.
        (self.cloud / 'data/linked.txt').symlink_to(outside)
        self.assert_release_rejected()
        self.assertEqual(outside.read_text(), 'must remain outside')

    def test_release_requires_an_exact_configured_item(self):
        self.seed_pair()
        self.assert_release_rejected(relative='data/result.json')
        result = self.run_merge('--release-local=data')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.local / 'data/result.json').is_file())

    def test_cloud_only_rejects_unsafe_paths_before_any_sync(self):
        self.write(self.local, 'safe.txt', 'should not upload on bad arguments')
        for name in ('', '.', '..', '../local', '/absolute', './data', 'data/../other',
                     'data/./child', 'data//child', 'data//', 'bad\\path', 'bad\npath',
                     'bad\tpath', 'bad\x7fpath', 'bad\u2028path', 'bad\u2029path', 'bad\u200bpath',
                     'data/*', 'data/?', 'data/[ab]', 'data/{a,b}'):
            with self.subTest(name=name):
                before = self.snapshot(self.local), self.snapshot(self.cloud)
                result = self.run_merge('--cloud-only=' + name)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
                self.assertFalse(self.state.exists())

    def test_one_trailing_slash_and_exact_duplicates_normalize_to_one_release_target(self):
        self.seed_pair()
        cloud_before = self.snapshot(self.cloud)
        self.successful('--cloud-only=data/', '--cloud-only=data', '--release-local=data/')
        self.assertFalse((self.local / 'data').exists())
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        histories = list((self.root / 'state.json.cloud-only-history').glob('*.json'))
        self.assertEqual(len(histories), 1)
        self.assertEqual(json.loads(histories[0].read_text())['prefixes'], ['data'])

    def test_duplicate_unicode_spellings_normalize_to_one_policy_entry(self):
        decomposed, composed = 'data/cafe\u0301', 'data/caf\u00e9'
        self.write(self.local, decomposed + '/result.txt', 'preserve cloud copy')
        self.write(self.cloud, decomposed + '/result.txt', 'preserve cloud copy')
        self.successful()
        (self.local / decomposed / 'result.txt').unlink()
        self.successful('--cloud-only=' + composed, '--cloud-only=' + decomposed + '/')
        self.assertEqual((self.cloud / decomposed / 'result.txt').read_text(), 'preserve cloud copy')
        histories = list((self.root / 'state.json.cloud-only-history').glob('*.json'))
        self.assertEqual(len(histories), 1)
        self.assertEqual(json.loads(histories[0].read_text())['prefixes'], [composed])

    def test_nested_policy_entries_are_rejected_in_either_order_after_normalization(self):
        self.write(self.local, 'safe.txt', 'must not sync with invalid policy')
        for paths in [('data', 'data/child'), ('data/child', 'data/'),
                      ('data/caf\u00e9', 'data/cafe\u0301/child')]:
            with self.subTest(paths=paths):
                before = self.snapshot(self.local), self.snapshot(self.cloud)
                result = self.run_merge(*(f'--cloud-only={name}' for name in paths))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('相互嵌套', result.stderr)
                self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
                self.assertFalse(self.state.exists())

    def test_policy_paths_over_4096_utf8_bytes_are_rejected_before_file_access(self):
        self.write(self.local, 'safe.txt', 'must not sync with oversized policy')
        for value in ('x' * 4097, '\u754c' * 1366):
            with self.subTest(bytes=len(value.encode('utf-8'))):
                before = self.snapshot(self.local), self.snapshot(self.cloud)
                result = self.run_merge('--cloud-only=' + value)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('4096', result.stderr)
                self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
                self.assertFalse(self.state.exists())

    def test_unicode_policy_normalization_keeps_prefix_boundaries(self):
        # A decomposed on-disk spelling must match the composed UI spelling,
        # including when that spelling is used by old anchor keys.
        actual = 'cache/cafe\u0301'
        configured = 'cache/caf\u00e9'
        self.write(self.local, actual + '/result.txt', 'preserve cloud copy')
        self.write(self.cloud, actual + '/result.txt', 'preserve cloud copy')
        self.successful()
        (self.local / actual / 'result.txt').unlink()
        self.write(self.cloud, actual + '-other/keep.txt', 'different prefix')
        cloud_before = self.snapshot(self.cloud / actual)
        self.successful('--cloud-only=' + configured)
        self.assertFalse((self.local / actual / 'result.txt').exists())
        self.assertEqual(self.snapshot(self.cloud / actual), cloud_before)
        self.assertEqual((self.local / (actual + '-other/keep.txt')).read_text(), 'different prefix')
        keys = json.loads(self.state.read_text())['files']
        self.assertNotIn(actual + '/result.txt', keys)

    def test_unicode_ancestor_tree_conflict_is_not_automatically_cleared(self):
        actual_parent = 'data/cafe\u0301'
        self.write(self.local, actual_parent + '/child/result.txt', 'protected evidence')
        self.write(self.cloud, actual_parent + '/child/result.txt', 'protected evidence')
        self.successful()
        state = json.loads(self.state.read_text())
        record = {'kind': 'tree', 'reason': 'directory_delete_edit', 'deletedSide': 'local'}
        state['conflicts'] = {actual_parent: record}
        self.state.write_text(json.dumps(state))
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        result = self.run_merge('--cloud-only=data/caf\u00e9/child')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {actual_parent: record})
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)

    def test_cloud_only_rejects_a_symbolic_link_ancestor(self):
        outside = self.root / 'outside'
        outside.mkdir()
        self.write(outside, 'child/evidence.txt', 'outside evidence')
        (self.local / 'linked').symlink_to(outside, target_is_directory=True)
        result = self.run_merge('--cloud-only=linked/child')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.state.exists())
        self.assertEqual((outside / 'child/evidence.txt').read_text(), 'outside evidence')

    def test_release_refuses_cloudstorage_as_the_local_working_copy(self):
        mirror = self.root / 'Library/CloudStorage/OneDrive-Fixture/work'
        self.write(mirror, 'data/file.txt', 'provider mirror')
        self.write(self.cloud, 'data/file.txt', 'provider mirror')
        before = self.snapshot(mirror), self.snapshot(self.cloud)
        result = self.run_merge('--cloud-only=data', '--release-local=data', local=mirror)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.snapshot(mirror), self.snapshot(self.cloud)), before)

    def test_release_refuses_conflicts_and_preserves_conflict_records(self):
        self.seed_pair()
        state = json.loads(self.state.read_text())
        for name, record in [('data/result.json', {'reason': 'fixture pending conflict'}),
                             ('data', {'kind': 'tree', 'reason': 'directory_delete_edit'})]:
            with self.subTest(name=name):
                state['conflicts'] = {name: record}
                self.state.write_text(json.dumps(state))
                self.assert_release_rejected()

    def test_cloud_only_preserves_conflict_records_during_normal_sync(self):
        self.seed_pair()
        state = json.loads(self.state.read_text())
        record = {'reason': 'fixture pending conflict'}
        state['conflicts'] = {'data/result.json': record}
        self.state.write_text(json.dumps(state))
        self.successful('--cloud-only=data')
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {'data/result.json': record})

    def test_cloud_only_keeps_an_ancestor_tree_conflict_without_resolving_it(self):
        self.seed_pair()
        self.write(self.local, 'data/child/result.json', 'child evidence')
        self.write(self.cloud, 'data/child/result.json', 'child evidence')
        state = json.loads(self.state.read_text())
        record = {'kind': 'tree', 'reason': 'directory_delete_edit', 'deletedSide': 'local'}
        state['conflicts'] = {'data': record}
        self.state.write_text(json.dumps(state))
        self.write(self.local, 'outside-report.txt', 'independent file')
        cloud_before = self.snapshot(self.cloud / 'data')
        result = self.run_merge('--cloud-only=data/child')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state.read_text())['conflicts'], {'data': record})
        self.assertEqual(self.snapshot(self.cloud / 'data'), cloud_before)
        self.assertEqual((self.cloud / 'outside-report.txt').read_text(), 'independent file')

    def test_deleted_local_parent_does_not_delete_its_cloud_only_child(self):
        self.seed_pair()
        # The existing file anchor deliberately has no representation of empty
        # directories; keep this fixture about the cloud-only child boundary.
        (self.local / 'data/empty').rmdir()
        (self.cloud / 'data/empty').rmdir()
        self.write(self.local, 'data/child/result.txt', 'cloud-only evidence')
        self.successful()
        self.successful('--cloud-only=data/child')
        shutil.rmtree(self.local / 'data')
        child_before = self.snapshot(self.cloud / 'data/child')
        self.successful('--cloud-only=data/child')
        self.assertEqual(self.snapshot(self.cloud / 'data/child'), child_before)
        self.assertFalse((self.cloud / 'data/result.json').exists())
        self.assertFalse((self.cloud / 'data/.hidden/evidence.txt').exists())

    def test_parent_delete_edit_conflict_preserves_cloud_only_content_and_other_files(self):
        self.seed_pair()
        self.write(self.local, 'data/child/result.txt', 'keep existing working copy')
        self.successful()
        self.successful('--cloud-only=data/child')
        shutil.rmtree(self.cloud / 'data')
        self.write(self.local, 'data/result.json', 'new local experiment result')
        self.write(self.local, 'outside-report.txt', 'independent report')
        local_child = self.snapshot(self.local / 'data/child')
        result = self.run_merge('--cloud-only=data/child')
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(self.local / 'data/child'), local_child)
        self.assertFalse((self.cloud / 'data').exists())
        self.assertEqual((self.local / 'data/result.json').read_text(), 'new local experiment result')
        self.assertEqual((self.cloud / 'outside-report.txt').read_text(), 'independent report')
        self.assertEqual(json.loads(self.state.read_text())['conflicts']['data']['kind'], 'tree')

    def test_manual_conflict_actions_cannot_bypass_a_cloud_only_target(self):
        self.seed_pair()
        for action in (('--resolve=data/result.json', '--choice=local'),
                       ('--review-newest=data/result.json',), ('--acknowledge=data/result.json',)):
            with self.subTest(action=action):
                before = self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()
                result = self.run_merge('--cloud-only=data', *action)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('云端保留', result.stderr)
                self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()), before)

    def test_manual_conflict_actions_cannot_bypass_a_cloud_only_sidecar(self):
        self.seed_pair()
        self.write(self.local, 'outside.txt', 'current main')
        self.write(self.cloud, 'outside.txt', 'current main')
        state = json.loads(self.state.read_text())
        state['conflicts'] = {'outside.txt': {
            'status': 'preserved', 'primary': 'local', 'sidecar': 'data/result.json'}}
        self.state.write_text(json.dumps(state))
        for action in (('--resolve=outside.txt', '--choice=both'),
                       ('--review-newest=outside.txt',), ('--acknowledge=outside.txt',)):
            with self.subTest(action=action):
                before = self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()
                result = self.run_merge('--cloud-only=data', *action)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('云端保留', result.stderr)
                self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()), before)

    def test_backup_restore_cannot_bypass_a_cloud_only_target(self):
        self.seed_pair()
        self.write(self.local, 'data/result.json', 'revised experiment result')
        self.successful()
        manifests = list((self.root / 'state-backups').glob('*/manifest.json'))
        metadata = next(json.loads(path.read_text()) for path in manifests
                        if json.loads(path.read_text())['name'] == 'data/result.json')
        before = self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()
        result = self.run_merge('--cloud-only=data', '--restore=' + metadata['id'])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('云端保留', result.stderr)
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()), before)

    def test_failed_verification_after_staging_rolls_back_but_does_not_restore_anchors(self):
        self.seed_pair()
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        verify = cloud_only.verify_copies
        calls = 0

        def fail_after_staging(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 1:
                return verify(*args, **kwargs)
            raise OSError('fixture: staged verification failed')

        with mock.patch.object(cloud_only, 'verify_copies', side_effect=fail_after_staging):
            with self.assertRaisesRegex(OSError, 'staged verification failed'):
                self.release_direct()
        self.assertEqual(calls, 2)
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
        state = json.loads(self.state.read_text())
        self.assertFalse(any(name.startswith('data/') for name in state['files']))
        journals = list(self.root.glob('.pathsync-local-release-*/release.json'))
        self.assertEqual(len(journals), 1)
        self.assertEqual(json.loads(journals[0].read_text())['status'], 'rolled_back')
        # The intentionally retired baseline stays retired after rollback too.
        # A resumed older client will rediscover equal data, not propagate a deletion.
        self.successful('--direction=upload')
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)

    def test_cleanup_failure_is_explicit_and_keeps_staging_payload_and_recovery_record(self):
        self.seed_pair()
        cloud_before = self.snapshot(self.cloud)
        local_payload = self.snapshot(self.local / 'data')
        with mock.patch.object(cloud_only.shutil, 'rmtree', side_effect=OSError('fixture cleanup failure')):
            with self.assertRaisesRegex(OSError, '本地清理未完成'):
                self.release_direct()
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        self.assertFalse((self.local / 'data').exists())
        staging = list(self.root.glob('.pathsync-local-release-*'))
        self.assertEqual(len(staging), 1)
        self.assertEqual(self.snapshot(staging[0] / 'payload'), local_payload)
        receipt = json.loads((staging[0] / 'release.json').read_text())
        self.assertEqual(receipt['status'], 'cleanup_incomplete')
        self.assertIn('fixture cleanup failure', receipt['error'])
        self.assertFalse(any(name.startswith('data/') for name in json.loads(self.state.read_text())['files']))

    def test_last_moment_staged_writer_update_is_rechecked_before_destruction(self):
        self.seed_pair()
        cloud_before = self.snapshot(self.cloud)
        save = cloud_only._save_receipt
        changed = False

        def mutate_after_cleanup_receipt(journal, state, receipt):
            nonlocal changed
            save(journal, state, receipt)
            if receipt['status'] == 'cleanup' and not changed:
                changed = True
                (journal.parent / 'payload/result.json').write_text('{"result": 9}')

        with mock.patch.object(cloud_only, '_save_receipt', side_effect=mutate_after_cleanup_receipt):
            with self.assertRaises(OSError):
                self.release_direct()
        self.assertTrue(changed, 'fixture must reach the final pre-cleanup boundary')
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        candidates = [self.local / 'data/result.json',
                      *self.root.glob('.pathsync-local-release-*/payload/result.json')]
        self.assertTrue(any(p.is_file() and p.read_text() == '{"result": 9}' for p in candidates),
                        'the late local update must remain in the restored target or recoverable staging')
        hidden = [self.local / 'data/.hidden/evidence.txt',
                  *self.root.glob('.pathsync-local-release-*/payload/.hidden/evidence.txt')]
        self.assertTrue(any(p.is_file() and p.read_text() == 'hidden evidence' for p in hidden))

    def test_target_recreated_before_cleanup_keeps_both_new_target_and_full_staged_copy(self):
        self.seed_pair()
        cloud_before = self.snapshot(self.cloud)
        original = self.snapshot(self.local / 'data')
        save = cloud_only._save_receipt
        recreated = False

        def recreate_after_cleanup_receipt(journal, state, receipt):
            nonlocal recreated
            save(journal, state, receipt)
            if receipt['status'] == 'cleanup' and not recreated:
                recreated = True
                self.write(self.local, 'data/unique.txt', 'new working copy from another process')

        with mock.patch.object(cloud_only, '_save_receipt', side_effect=recreate_after_cleanup_receipt):
            with self.assertRaisesRegex(OSError, '重新创建'):
                self.release_direct()
        self.assertTrue(recreated)
        self.assertEqual((self.local / 'data/unique.txt').read_text(), 'new working copy from another process')
        self.assertEqual(set(self.snapshot(self.local / 'data')), {'unique.txt'})
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        stages = list(self.root.glob('.pathsync-local-release-*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual(self.snapshot(stages[0] / 'payload'), original)
        self.assertNotEqual(json.loads((stages[0] / 'release.json').read_text())['status'], 'released')

    def test_target_recreated_after_cleanup_is_preserved_and_never_reported_as_released(self):
        self.seed_pair()
        cloud_before = self.snapshot(self.cloud)
        remove = cloud_only.shutil.rmtree
        recreated = False

        def recreate_after_removal(path, *args, **kwargs):
            nonlocal recreated
            remove(path, *args, **kwargs)
            if Path(path).name == 'payload' and not recreated:
                recreated = True
                self.write(self.local, 'data/unique.txt', 'new copy after cleanup')

        with mock.patch.object(cloud_only.shutil, 'rmtree', side_effect=recreate_after_removal):
            with self.assertRaisesRegex(OSError, '重新创建'):
                self.release_direct()
        self.assertTrue(recreated)
        self.assertEqual((self.local / 'data/unique.txt').read_text(), 'new copy after cleanup')
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        journals = list(self.root.glob('.pathsync-local-release-*/release.json'))
        self.assertEqual(len(journals), 1)
        self.assertEqual(json.loads(journals[0].read_text())['status'], 'new_working_copy_present')
        self.assertFalse(any(name.startswith('data/') for name in json.loads(self.state.read_text())['files']))

    def test_release_then_cancel_policy_merge_redownloads_without_cloud_deletion(self):
        self.seed_pair()
        self.successful('--cloud-only=data', '--release-local=data')
        cloud_before = self.snapshot(self.cloud)
        self.successful()
        self.assertEqual((self.local / 'data/result.json').read_text(), '{"result": 7}')
        self.assertEqual((self.local / 'data/.hidden/evidence.txt').read_text(), 'hidden evidence')
        self.assertEqual(self.snapshot(self.cloud), cloud_before)

    def test_released_anchors_are_safe_when_an_old_or_different_direction_run_resumes(self):
        self.seed_pair()
        self.successful('--cloud-only=data', '--release-local=data')
        cloud_before = self.snapshot(self.cloud)
        # No policy flag simulates an older client losing this Mac's selection.
        self.successful('--direction=upload')
        self.assertFalse((self.local / 'data').exists())
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        self.successful('--direction=download')
        self.assertEqual((self.local / 'data/result.json').read_text(), '{"result": 7}')
        self.assertEqual(self.snapshot(self.cloud), cloud_before)

    def test_normal_cloud_only_anchor_reset_protects_manual_local_removal(self):
        self.seed_pair()
        self.successful('--cloud-only=data')
        shutil.rmtree(self.local / 'data')
        cloud_before = self.snapshot(self.cloud)
        self.successful('--direction=upload')
        self.assertFalse((self.local / 'data').exists())
        self.assertEqual(self.snapshot(self.cloud), cloud_before)
        self.successful()
        self.assertEqual((self.local / 'data/result.json').read_text(), '{"result": 7}')
        self.assertEqual(self.snapshot(self.cloud), cloud_before)

    def test_metadata_only_retirement_changes_no_data_and_allows_safe_later_redownload(self):
        self.seed_pair()
        self.write(self.local, 'models/weights.bin', 'model fixture')
        self.successful()
        shutil.rmtree(self.local / 'data')
        self.write(self.local, 'outside-new.txt', 'do not upload during retirement')
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        self.successful('--retire-cloud-only', '--cloud-only=data', '--cloud-only=models')
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
        state = json.loads(self.state.read_text())
        self.assertFalse(any(name == 'data' or name.startswith('data/') or
                             name == 'models' or name.startswith('models/') for name in state['files']))
        self.assertIn('data-other/report.txt', state['files'])
        histories = list((self.root / 'state.json.cloud-only-history').glob('*.json'))
        self.assertEqual(len(histories), 1)
        self.assertEqual(json.loads(histories[0].read_text())['prefixes'], ['data', 'models'])
        self.assertFalse((self.cloud / 'outside-new.txt').exists())
        self.successful()
        self.assertEqual((self.local / 'data/result.json').read_text(), '{"result": 7}')
        self.assertEqual((self.local / 'data/.hidden/evidence.txt').read_text(), 'hidden evidence')
        self.assertEqual((self.cloud / 'data/result.json').read_text(), '{"result": 7}')
        self.assertEqual((self.cloud / 'models/weights.bin').read_text(), 'model fixture')

    def test_metadata_only_retirement_never_scans_hashes_syncs_or_migrates_backups(self):
        self.seed_pair()
        drive = self.root / 'backup-drive'
        drive.mkdir()
        arguments = [str(HELPER), str(self.local), str(self.cloud), str(self.state),
                     '--shared-excludes', '--retire-cloud-only', '--cloud-only=data',
                     '--backup-root=' + str(drive), '--backup-subpath=fixture-pair']
        before = self.snapshot(self.local), self.snapshot(self.cloud)
        with mock.patch.object(sys, 'argv', arguments), \
                mock.patch.object(cloud_only, 'safe_target', side_effect=AssertionError('must not probe targets')) as target, \
                mock.patch.object(Path, 'resolve', side_effect=AssertionError('must not resolve roots')) as resolve, \
                mock.patch.object(cloud_only, 'inventory', side_effect=AssertionError('must not scan')) as inventory, \
                mock.patch.object(cloud_only, 'secure_digest', side_effect=AssertionError('must not read file data')) as digest, \
                mock.patch.object(sync_merge, 'sync_files', side_effect=AssertionError('must not sync')) as sync, \
                mock.patch.object(sync_merge, 'move_backups', side_effect=AssertionError('must not migrate')) as migration, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(sync_merge.main(), 0)
        for operation in (target, resolve, inventory, digest, sync, migration):
            operation.assert_not_called()
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud)), before)
        self.assertEqual(list(drive.iterdir()), [])
        self.assertFalse(any(name.startswith('data/') for name in json.loads(self.state.read_text())['files']))

    def test_metadata_only_retirement_succeeds_when_both_data_roots_have_disappeared(self):
        self.seed_pair()
        moved_local, moved_cloud = self.root / 'moved-local', self.root / 'moved-cloud'
        self.local.rename(moved_local)
        self.cloud.rename(moved_cloud)
        before = self.snapshot(moved_local), self.snapshot(moved_cloud)
        self.successful('--retire-cloud-only', '--cloud-only=data')
        self.assertFalse(self.local.exists())
        self.assertFalse(self.cloud.exists())
        self.assertEqual((self.snapshot(moved_local), self.snapshot(moved_cloud)), before)
        state = json.loads(self.state.read_text())
        self.assertFalse(any(name.startswith('data/') for name in state['files']))
        self.assertIn('data-other/report.txt', state['files'])
        self.assertEqual(state['local'], str(self.local))
        self.assertEqual(state['cloud'], str(self.cloud))

    def test_metadata_only_retirement_does_not_follow_a_replacement_target_symlink(self):
        self.seed_pair()
        saved_data = self.root / 'saved-original-data'
        (self.local / 'data').rename(saved_data)
        outside = self.root / 'outside'
        self.write(outside, 'unique.txt', 'do not follow or remove this')
        (self.local / 'data').symlink_to(outside, target_is_directory=True)
        before = (self.snapshot(self.local), self.snapshot(self.cloud),
                  self.snapshot(saved_data), self.snapshot(outside))
        self.successful('--retire-cloud-only', '--cloud-only=data')
        self.assertTrue((self.local / 'data').is_symlink())
        self.assertEqual(os.readlink(self.local / 'data'), str(outside))
        self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud),
                          self.snapshot(saved_data), self.snapshot(outside)), before)
        self.assertFalse(any(name.startswith('data/') for name in json.loads(self.state.read_text())['files']))

    def test_metadata_only_retirement_requires_policy_and_rejects_other_actions(self):
        self.seed_pair()
        drive = self.root / 'backup-drive'
        drive.mkdir()
        invalid = [(), ('--dry-run',), ('--resolve=data/result.json', '--choice=local'),
                   ('--review-newest=data/result.json',), ('--acknowledge=data/result.json',),
                   ('--restore=' + '0' * 32,), ('--release-local=data',),
                   ('--migrate-backups', '--backup-root=' + str(drive), '--backup-subpath=fixture-pair')]
        for index, action in enumerate(invalid):
            with self.subTest(action=action):
                before = self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()
                policy = () if index == 0 else ('--cloud-only=data',)
                result = self.run_merge('--retire-cloud-only', *policy, *action)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.snapshot(self.local), self.snapshot(self.cloud), self.state.read_bytes()), before)
                self.assertFalse((self.root / 'state.json.cloud-only-history').exists())
                self.assertEqual(list(drive.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
