import pathlib
import subprocess
import sys
import tempfile

def main():
    helper = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(dir=sys.argv[2]) as directory:
        root = pathlib.Path(directory)
        installed = root / 'current' / 'PathSync.app'
        staged = root / 'stage' / 'unpacked' / 'PathSync.app'
        installed.mkdir(parents=True)
        staged.mkdir(parents=True)
        (installed / 'marker').write_text('old')
        (staged / 'marker').write_text('new')
        parent = subprocess.Popen(['/usr/bin/true'])
        parent.wait()
        subprocess.run([str(helper), str(installed), str(staged), str(parent.pid)], check=True)
        assert (installed / 'marker').read_text() == 'new'
        previous = installed.parent / 'test-update-backups' / 'previous.bundle-backup'
        assert (previous / 'marker').read_text() == 'old'
        assert not (installed.parent / '.路径同步.previous.app').exists()
        assert not (root / 'stage').exists()

        parent = subprocess.Popen(['/usr/bin/true'])
        parent.wait()
        missing = root / 'missing' / 'unpacked' / 'PathSync.app'
        result = subprocess.run([str(helper), str(installed), str(missing), str(parent.pid)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode != 0
        assert (installed / 'marker').read_text() == 'new'
        assert (previous / 'marker').read_text() == 'old'
    print('Updater preserves the old app outside Applications; missing stages leave the install untouched.')


if __name__ == "__main__":
    main()
