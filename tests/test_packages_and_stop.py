import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import graph_index
import mac_packages as p
import sync_merge as m


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.local, self.cloud = self.root / 'local', self.root / 'cloud'
        self.local.mkdir(); self.cloud.mkdir()
        self.name = 'project/Python.framework (date:time)'
        self.mirror = self.name + ' 2'
        for root in (self.local, self.cloud):
            (root / 'project').mkdir()
            (root / self.name).write_bytes(b'ordinary file, never replace')
        (self.cloud / self.mirror / 'Versions/3.9/lib/empty').mkdir(parents=True)

    def attrs(self, path, key):
        if Path(path) == self.cloud / self.mirror:
            if key == 'com.apple.FinderInfo':
                return b'\0' * 8 + b'\x20\0' + b'\0' * 22
            if key == 'com.apple.fileprovider.before-bounce#PX':
                return Path(self.name).name.encode() + b'\0'
        return None

    def test_verified_collision_maps_only_package(self):
        with mock.patch.object(p, 'attribute', side_effect=self.attrs):
            self.assertEqual(p.resolve(self.cloud, self.name + '.pkgf'), self.mirror)
        self.assertEqual((self.local / self.name).read_bytes(), b'ordinary file, never replace')

    def test_number_suffix_alone_is_never_identity(self):
        with mock.patch.object(p, 'attribute', return_value=None):
            self.assertIsNone(p.resolve(self.cloud, self.name + '.pkgf'))

    def test_exact_literal_pkgf_is_an_ordinary_file(self):
        (self.cloud / (self.name + '.pkgf')).write_bytes(b'literal')
        with mock.patch.object(p, 'attribute', side_effect=self.attrs):
            self.assertIsNone(p.resolve(self.cloud, self.name + '.pkgf'))

    def test_ambiguous_package_mapping_fails_closed(self):
        extra = self.cloud / (self.name + ' 3'); extra.mkdir()
        def attrs(path, key):
            return self.attrs(self.cloud / self.mirror, key)
        with mock.patch.object(p, 'attribute', side_effect=attrs):
            with self.assertRaisesRegex(OSError, '多个'):
                p.resolve(self.cloud, self.name + '.pkgf')

    def test_symlink_parent_and_symlink_package_rejected(self):
        (self.cloud / 'alias').symlink_to(self.cloud / 'project')
        with self.assertRaises(OSError):
            p.resolve(self.cloud, 'alias/item.pkgf')
        import shutil
        shutil.rmtree(self.cloud / self.mirror)
        (self.cloud / self.mirror).symlink_to(self.local)
        with mock.patch.object(p, 'attribute', side_effect=self.attrs):
            self.assertIsNone(p.resolve(self.cloud, self.name + '.pkgf'))

    def args(self, **extra):
        args = SimpleNamespace(local=self.local, cloud=self.cloud, state=self.root / 'state.json',
              conflict_policy='keep-both', cloud_only=[], shared_excludes=True,
              exclude_rules=m.ExcludeRules([]), backup_root=None, backup_subpath=None,
              backup_count=0, backup_retention_days=15, dry_run=False, direction='merge',
              plan_json=True, hydrate_online_only=False, download_online_content=False,
              graph_index=SimpleNamespace(verified_common=lambda *args: None, entries={self.name + '.pkgf': {
                  'kind': 'package', 'mirror_name': self.mirror, 'size': 13312}}))
        for key, value in extra.items():
            setattr(args, key, value)
        args.backups = m.BackupPlace(args)
        return args

    def run_package(self, **extra):
        args = self.args(**extra)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = m.sync_files(args, self.local, self.cloud, {}, {})
        return code, output.getvalue()

    def test_empty_package_copy_preserves_same_named_file_and_empty_dirs(self):
        code, output = self.run_package()
        self.assertEqual(code, 0, output)
        self.assertTrue((self.local / self.mirror / 'Versions/3.9/lib/empty').is_dir())
        self.assertEqual((self.local / self.name).read_bytes(), b'ordinary file, never replace')
        self.assertFalse((self.local / (self.name + '.pkgf')).exists())
        state = json.loads((self.root / 'state.json').read_text())
        self.assertFalse(any(key.startswith(self.mirror) for key in state['files']))
        code, output = self.run_package()
        self.assertEqual(code, 0, output)
        self.assertIn('downloaded=0', output)

    def test_package_preview_never_copies(self):
        with mock.patch.object(p, 'copy_missing', side_effect=AssertionError('preview copy')):
            code, output = self.run_package(dry_run=True)
        self.assertEqual(code, 0, output)
        self.assertIn('"kind": "package"', output)
        self.assertFalse((self.local / self.mirror).exists())
        self.assertFalse((self.root / 'state.json').exists())

    def test_stale_package_metadata_protects_entire_package(self):
        args = self.args()
        args.graph_index.entries[self.name + '.pkgf']['metadata_ready'] = False
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = m.sync_files(args, self.local, self.cloud, {}, {})
        self.assertEqual(code, 2, output.getvalue())
        self.assertFalse((self.local / self.mirror).exists())

    def test_cloud_only_and_exclusion_skip_both_serialized_and_mirror_paths(self):
        for settings in ({'cloud_only': ['project']},
                         {'exclude_rules': m.ExcludeRules([self.mirror + '/'])}):
            with mock.patch.object(p, 'copy_missing', side_effect=AssertionError('excluded copy')):
                code, output = self.run_package(**settings)
            self.assertEqual(code, 0, output)
            self.assertFalse((self.local / self.mirror).exists())

    def test_differing_packages_are_preserved_instead_of_overwritten(self):
        (self.local / self.mirror).mkdir()
        (self.local / self.mirror / 'user.txt').write_text('local edit')
        code, output = self.run_package()
        self.assertEqual(code, 2, output)
        self.assertIn('包内容不同', output)
        self.assertEqual((self.local / self.mirror / 'user.txt').read_text(), 'local edit')
        self.assertFalse((self.cloud / self.mirror / 'user.txt').exists())

    def test_late_target_arrival_is_never_replaced(self):
        original = p.publish_exclusive
        def arrival(source, target):
            target.mkdir()
            (target / 'arrival.txt').write_text('new user data')
            return original(source, target)
        with mock.patch.object(p, 'publish_exclusive', side_effect=arrival):
            with self.assertRaises(FileExistsError):
                p.copy_missing(self.cloud, self.local, self.mirror, m.digest, lambda: None)
        self.assertEqual((self.local / self.mirror / 'arrival.txt').read_text(), 'new user data')
        self.assertFalse(list((self.local / 'project').glob('*.researchsync-partial')))

    def test_internal_symlink_copied_without_following_external_target(self):
        outside = self.root / 'outside.txt'; outside.write_text('private outside bytes')
        (self.cloud / self.mirror / 'external').symlink_to(outside)
        p.copy_missing(self.cloud, self.local, self.mirror, m.digest, lambda: None)
        self.assertTrue((self.local / self.mirror / 'external').is_symlink())
        self.assertEqual(outside.read_text(), 'private outside bytes')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS authorization and document metadata')
    def test_mac_authorization_added_after_copy_is_not_a_document_change(self):
        p.copy_missing(self.cloud, self.local, self.mirror, m.digest, lambda: None)
        original = p.subprocess.run
        def authorization(arguments, **kwargs):
            result = original(arguments, **kwargs)
            if arguments == ['/usr/bin/xattr', str(self.local / self.mirror)]:
                result.stdout += b'com.apple.macl\n'
            return result
        with mock.patch.object(p.subprocess, 'run', side_effect=authorization):
            self.assertEqual(p.snapshot(self.cloud / self.mirror, m.digest, lambda: None),
                             p.snapshot(self.local / self.mirror, m.digest, lambda: None))
        # Document tags/forks must still participate in verification.
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.metadata:_kMDItemUserTags',
                        'user tag', str(self.local / self.mirror)], check=True)
        self.assertNotEqual(p.snapshot(self.cloud / self.mirror, m.digest, lambda: None),
                            p.snapshot(self.local / self.mirror, m.digest, lambda: None))


class StopTests(unittest.TestCase):
    def test_stop_does_not_wait_for_blocked_read_only_directory_threads(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            local, cloud, state, stop = [root / name for name in ('local', 'cloud', 'state.json', 'stop.json')]
            local.mkdir(); cloud.mkdir()
            token = str(uuid.uuid4())
            script = '''import sys,time,runpy,os
import sync_merge as m
original=os.scandir
def blocked(path):
    time.sleep(30)
    return original(path)
os.scandir=blocked
runpy.run_path(m.__file__,run_name='__main__')
'''
            process = subprocess.Popen([sys.executable, '-c', script, str(local), str(cloud), str(state),
                        '--shared-excludes', '--run-id', token, '--stop-file', str(stop)],
                        cwd=Path(m.__file__).parent, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn('SCAN', process.stdout.readline())
                stop.write_text(json.dumps({'runID': token}))
                output, error = process.communicate(timeout=4)
                self.assertEqual(process.returncode, 130, output + error)
                self.assertTrue(state.is_file())
            finally:
                if process.poll() is None:
                    process.kill(); process.communicate()

    def test_only_owned_download_readers_are_cancelled(self):
        import sync_cancel
        owned = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'])
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'])
        try:
            sync_cancel.reader_started(owned)
            sync_cancel.cancel_readers()
            owned.wait(timeout=3)
            self.assertIsNone(unrelated.poll())
        finally:
            sync_cancel.reader_finished(owned)
            for process in (owned, unrelated):
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=3)
    def test_stop_preserves_completed_files_and_checkpoint_then_next_run_continues(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            local, cloud, state, stop = [root / name for name in ('local', 'cloud', 'state.json', 'stop.json')]
            local.mkdir(); cloud.mkdir()
            for index in range(12):
                (cloud / f'{index:02}.txt').write_bytes(f'original {index}'.encode())
            token = str(uuid.uuid4())
            # Delay a real atomic copy. Cancellation occurs while an unpublished
            # transfer exists, after earlier files were fully committed.
            script = '''import sys,time,runpy
import sync_merge as m
original=m.shutil.copy2
def slow(source,target,*a,**k):
    result=original(source,target,*a,**k)
    time.sleep(.3)
    return result
m.shutil.copy2=slow
try: sys.exit(m.main())
except m.sync_cancel.Cancelled:
    m.sync_cancel.cancel_readers();print('STOPPED\\nstopped=1');sys.exit(130)
'''
            command = [sys.executable, '-c', script, str(local), str(cloud), str(state),
                       '--shared-excludes', '--run-id', token, '--stop-file', str(stop)]
            stop.write_text(json.dumps({'runID': str(uuid.uuid4())}))  # stale request ignored
            process = subprocess.Popen(command, cwd=m.Path(__file__).resolve().parents[1],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 8
                while len(list(local.glob('*.txt'))) < 2 and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertGreaterEqual(len(list(local.glob('*.txt'))), 2)
                requested = time.monotonic()
                stop.write_text(json.dumps({'runID': token}))
                output, error = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 130, output + error)
                self.assertLess(time.monotonic() - requested, 3)
                self.assertIn('stopped=1', output)
                self.assertTrue(state.exists())
                completed = list(local.glob('*.txt'))
                self.assertLess(len(completed), 12)
                for path in completed:
                    self.assertEqual(path.read_bytes(), (cloud / path.name).read_bytes())
                self.assertFalse(list(local.glob('*.researchsync-partial')))
                checkpoint = json.loads(state.read_text())['files']
                self.assertGreaterEqual(len(checkpoint), 2)
                command = [sys.executable, str(Path(m.__file__)), str(local), str(cloud), str(state),
                           '--shared-excludes', '--run-id', str(uuid.uuid4()), '--stop-file', str(stop)]
                again = subprocess.run(command, capture_output=True, text=True, timeout=10)
                self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
                self.assertEqual(len(list(local.glob('*.txt'))), 12)
            finally:
                if process.poll() is None:
                    process.kill(); process.communicate()


if __name__ == '__main__':
    unittest.main()
