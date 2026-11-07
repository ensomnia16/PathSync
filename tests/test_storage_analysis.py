import os
from pathlib import Path
import tempfile
import unittest

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
