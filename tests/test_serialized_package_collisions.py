"""File Provider can expose a .pkgf archive and reverse collision order per Mac."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import graph_index as g
import mac_packages as p
import sync_merge as m


class SerializedCollisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cloud, self.local = self.root / 'cloud', self.root / 'local'
        self.cloud.mkdir(); self.local.mkdir()
        self.base = 'bundle:time'; self.second = self.base + ' 2'; self.serialized = self.base + '.pkgf'
        for root in (self.cloud, self.local):
            (root / self.base).write_bytes(b'archive package')
            (root / self.second).write_bytes(b'ordinary tar document')
        stamp = 1_700_000_000_000_000_000
        for path in self.cloud.iterdir(): os.utime(path, ns=(stamp, stamp))
        self.entries = {
            self.base: {'id': 'ordinary', 'size': (self.cloud/self.second).stat().st_size,
                        'quick': g.content_hashes(self.cloud/self.second)['quickXorHash'], 'mtime': stamp},
            self.serialized: {'id': 'package', 'size': (self.cloud/self.base).stat().st_size,
                        'quick': g.content_hashes(self.cloud/self.base)['quickXorHash'], 'mtime': stamp}}

    def attributes(self, path, key):
        if Path(path).name not in (self.base, self.second): return None
        if key == 'com.apple.FinderInfo': return b'\0'*8+b'\x20\0'+b'\0'*22
        if key == 'com.apple.fileprovider.before-bounce#PX' and Path(path).name == self.second:
            return self.base.encode()+b'\0'

    def resolve(self, excluded=lambda _: False, materialize=None):
        with mock.patch.object(p, 'attribute', side_effect=self.attributes):
            return g.resolve_serialized_collisions(self.entries, self.cloud, excluded, materialize)

    def test_reversed_order_maps_both_ids_without_renaming_or_rewriting(self):
        before = {f.name: f.read_bytes() for f in self.cloud.iterdir()}
        result, protected = self.resolve()
        self.assertEqual(result[self.base]['id'], 'package')
        self.assertEqual(result[self.second]['id'], 'ordinary')
        self.assertEqual(result[self.base]['remote_name'], self.serialized)
        self.assertFalse(protected)
        self.assertNotIn(self.serialized, result)
        self.assertEqual({f.name: f.read_bytes() for f in self.cloud.iterdir()}, before)
        self.assertEqual(self.entries[self.base]['id'], 'ordinary', 'input must stay unchanged')

    def test_sync_preserves_both_existing_working_files(self):
        args = SimpleNamespace(local=self.local, cloud=self.cloud, state=self.root/'state.json',
            conflict_policy='keep-both', cloud_only=[], shared_excludes=True,
            exclude_rules=m.ExcludeRules([]), backup_root=None, backup_subpath=None,
            backup_count=0, backup_retention_days=15, dry_run=False, direction='merge',
            plan_json=False, hydrate_online_only=False, download_online_content=False,
            graph_index=SimpleNamespace(entries=self.entries, verified_common=lambda *a: None))
        args.backups = m.BackupPlace(args)
        before = {f.name: f.read_bytes() for f in self.local.iterdir()}
        output = io.StringIO()
        with mock.patch.object(p, 'attribute', side_effect=self.attributes), contextlib.redirect_stdout(output):
            code = m.sync_files(args, self.local, self.cloud, {}, {})
        self.assertEqual(code, 0, output.getvalue())
        self.assertIn('uploaded=0 downloaded=0 unchanged=2', output.getvalue())
        self.assertEqual({f.name: f.read_bytes() for f in self.local.iterdir()}, before)

    def test_wrong_or_duplicate_hashes_fail_closed(self):
        self.entries[self.serialized]['quick'] = 'no-match'
        with self.assertRaises(g.IndexError): self.resolve()
        self.entries[self.serialized]['quick'] = self.entries[self.base]['quick']
        self.entries[self.serialized]['size'] = self.entries[self.base]['size']
        with self.assertRaises(g.IndexError): self.resolve()

    def test_multiple_matching_candidates_are_not_guessed(self):
        (self.cloud/self.second).write_bytes((self.cloud/self.base).read_bytes())
        os.utime(self.cloud/self.second, ns=(self.entries[self.serialized]['mtime'],)*2)
        with self.assertRaises(g.IndexError): self.resolve()

    def test_filename_suffix_and_unmarked_file_do_not_prove_package_identity(self):
        with mock.patch.object(p, 'attribute', return_value=None):
            self.assertEqual(g.resolve_serialized_collisions(self.entries, self.cloud, lambda _: False),
                             (self.entries, set()))

    def test_literal_pkgf_file_keeps_its_own_identity(self):
        (self.cloud/self.serialized).write_bytes(b'literal')
        result, protected = self.resolve()
        self.assertEqual(result, self.entries)
        self.assertFalse(protected)

    def test_symlink_candidate_is_not_read(self):
        (self.cloud/self.second).unlink(); (self.cloud/self.second).symlink_to(self.local/self.second)
        real = g.content_hashes
        def checked(path):
            self.assertFalse(path.is_symlink())
            return real(path)
        with mock.patch.object(g, 'content_hashes', side_effect=checked):
            with self.assertRaises(g.IndexError): self.resolve()

    def test_excluded_collision_member_protects_whole_group_without_reading(self):
        with mock.patch.object(g, 'content_hashes', side_effect=AssertionError('excluded data read')):
            result, protected = self.resolve(excluded=lambda key: key.endswith('.pkgf'))
        self.assertEqual(result, self.entries)
        self.assertEqual(protected, {self.base, self.second, self.serialized})

    def test_cloud_only_group_does_not_even_enumerate_candidates(self):
        with mock.patch.object(p, 'serialized_candidates', side_effect=AssertionError('cloud-only scan')):
            self.assertEqual(g.resolve_serialized_collisions(self.entries, self.cloud, lambda _: True),
                             (self.entries, set()))

    def dataless_fixture(self, path):
        real = path.lstat()
        fields = {key: getattr(real, key) for key in dir(real) if key.startswith('st_')}
        fields['st_flags'] = 0x40000000
        return SimpleNamespace(**fields)

    def test_preview_never_downloads_for_identity_check(self):
        real = Path.lstat
        fake = self.dataless_fixture(self.cloud/self.base)
        with mock.patch.object(Path, 'lstat', side_effect=lambda path: fake if path==self.cloud/self.base else real(path), autospec=True):
            with self.assertRaisesRegex(g.IndexError, '预览未下载'): self.resolve()

    def test_normal_run_materializes_only_the_matching_candidate_group(self):
        real = Path.lstat; calls=[]; fake=self.dataless_fixture(self.cloud/self.base)
        def lookup(path): return fake if path==self.cloud/self.base and not calls else real(path)
        with mock.patch.object(Path, 'lstat', side_effect=lookup, autospec=True):
            result, _ = self.resolve(materialize=lambda path: calls.append(path))
        self.assertEqual(calls, [self.cloud/self.base])
        self.assertEqual(result[self.base]['id'], 'package')

    def test_changes_after_hashing_are_rejected(self):
        real = g.content_hashes
        def changed(path):
            result = real(path)
            os.utime(path, ns=(path.stat().st_atime_ns, path.stat().st_mtime_ns+2_000_000_000))
            return result
        with mock.patch.object(g, 'content_hashes', side_effect=changed):
            with self.assertRaisesRegex(g.IndexError, '发生变化'): self.resolve()

    def test_target_claimed_by_unrelated_graph_item_is_not_overwritten(self):
        self.entries[self.second] = {**self.entries[self.base], 'id': 'unrelated'}
        with self.assertRaises(g.IndexError): self.resolve()


if __name__ == '__main__': unittest.main()
