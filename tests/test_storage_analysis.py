import os
from pathlib import Path
import tempfile
import unittest
import json
import io
import contextlib
import sys
from unittest import mock
import graph_index
import storage_analysis

from storage_analysis import analyze


class StorageAnalysisTests(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.local = Path(work.name) / 'local'
        self.cloud = Path(work.name) / 'cloud'
        self.local.mkdir()
        self.cloud.mkdir()

    def write(self, root, path, content):
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(content)
        return file.stat().st_blocks * 512

    def test_distinguishes_same_size_from_identical_content(self):
        same = self.write(self.local, 'group/same', b'x' * 4096)
        different = self.write(self.local, 'group/different', b'y' * 4096)
        missing = self.write(self.local, 'group/missing', b'z' * 4096)
        self.write(self.cloud, 'group/same', b'x' * 4096)
        self.write(self.cloud, 'group/different', b'q' * 4096)
        metadata = analyze(self.local, self.cloud)['rows'][0]['usage']
        self.assertEqual(metadata['localBytes'], same + different + missing)
        self.assertEqual(metadata['unverifiedBytes'], same + different)
        self.assertEqual(metadata['verifiedBytes'], 0)
        verified = analyze(self.local, self.cloud, 'group', verify=True)
        self.assertEqual(verified['totals']['verifiedBytes'], same)
        self.assertEqual(verified['totals']['differentBytes'], different + missing)
        self.assertEqual(verified['totals']['unverifiedBytes'], 0)
        self.assertFalse(next(row for row in verified['rows']
                              if row['path'] == 'group/missing')['selectable'])

    def test_symlinks_are_not_followed_and_hard_links_count_once(self):
        size = self.write(self.local, 'group/source', b'x' * 4096)
        self.write(self.cloud, 'group/source', b'x' * 4096)
        os.link(self.local / 'group/source', self.local / 'group/second-link')
        (self.local / 'link').symlink_to(self.cloud / 'group')
        report = analyze(self.local, self.cloud)
        self.assertEqual(report['totals']['localBytes'], size)
        link = next(row for row in report['rows'] if row['path'] == 'link')
        self.assertFalse(link['selectable'])
        self.assertFalse(link['isDirectory'])


class CloudLogicalStorageTests(unittest.TestCase):
    setUp = StorageAnalysisTests.setUp
    def index(self):
        path = self.local.parent / 'cloud-index.sqlite'
        def fetch(url):
            if '/root:/' in url:
                return {'id':'root','name':'cloud','folder':{}}
            return {'value':[
                {'id':'dir','name':'online','folder':{},'parentReference':{'id':'root'}},
                {'id':'big','name':'video.mov','size':2000000000,'file':{},'parentReference':{'id':'dir'}},
                {'id':'text','name':'note.txt','size':7,'file':{},'parentReference':{'id':'root'}}],
                '@odata.deltaLink':'https://graph.microsoft.com/v1.0/drives/d/items/root/delta?token=test'}
        g=graph_index.GraphIndex(path,self.local,self.cloud,'d','cloud',fetch)
        try:g.refresh()
        finally:g.close()
        return path

    def test_remote_only_data_counts_without_reading_or_materializing(self):
        index=self.index()
        with mock.patch.object(storage_analysis,'secure_digest',side_effect=AssertionError('content read')):
            report=analyze(self.local,self.cloud,cloud_index=index)
        self.assertEqual(report['totals']['cloudLogicalBytes'],2000000007)
        self.assertEqual(report['totals']['cloudBytes'],0)
        self.assertTrue(report['cloudIndexUpdatedAt']>0)
        rows={r['path']:r for r in report['rows']}
        self.assertEqual(rows['online']['usage']['cloudLogicalBytes'],2000000000)
        self.assertTrue(rows['online']['isDirectory'])
        self.assertTrue(rows['online']['hasCloud'])
        self.assertFalse((self.cloud/'online').exists())
        self.assertFalse((self.local/'online').exists())

    def test_browse_remote_only_scope_uses_same_snapshot(self):
        report=analyze(self.local,self.cloud,scope='online',cloud_index=self.index())
        self.assertEqual(report['totals']['cloudLogicalBytes'],2000000000)
        self.assertEqual(report['rows'][0]['path'],'online/video.mov')
        self.assertFalse(report['rows'][0]['isDirectory'])

    def test_missing_index_is_unknown_not_zero(self):
        report=analyze(self.local,self.cloud,cloud_index=self.local.parent/'missing.sqlite')
        self.assertIsNone(report['totals']['cloudLogicalBytes'])
        self.assertIsNotNone(report['cloudIndexWarning'])

    def test_wrong_local_binding_cannot_show_stale_size(self):
        index=self.index();other=self.local.parent/'other';other.mkdir()
        report=analyze(other,self.cloud,cloud_index=index)
        self.assertIsNone(report['totals']['cloudLogicalBytes'])
        self.assertIsNotNone(report['cloudIndexWarning'])

    def test_failed_refresh_preserves_cached_size_and_reports_warning(self):
        index=self.index();out=io.StringIO()
        args=['storage_analysis.py',str(self.local),str(self.cloud),'--cloud-index',str(index),
              '--refresh-cloud-index','--graph-auth-helper','/fixture','--onedrive-root',str(self.cloud.parent)]
        with mock.patch.object(sys,'argv',args),contextlib.redirect_stdout(out), \
             mock.patch.object(graph_index,'credentials',return_value={'access_token':'fixture','drive_id':'d'}), \
             mock.patch.object(graph_index.GraphClient,'get',side_effect=graph_index.HTTPFailure(503,'unavailable')):
            storage_analysis.main()
        report=json.loads(out.getvalue())
        self.assertEqual(report['totals']['cloudLogicalBytes'],2000000007)
        self.assertIn('刷新未完成',report['cloudIndexWarning'])
