#!/usr/bin/env python3
"""Sign PathSync with the existing private code-signing identity on this Mac."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = 'com.ensom.ResearchSync'


def sign_app(app, adhoc=False):
    app = app.resolve(strict=True)
    if app.suffix != '.app':
        raise ValueError('An application bundle is required.')
    helper = app / 'Contents/Resources/UpdateApply'
    pin = re.search(r'pathSyncCodeSigningCertificateSHA1 = "([A-F0-9]{40})"',
                    (ROOT / 'CodeSigningIdentity.swift').read_text()).group(1)
    if hashlib.sha1((ROOT / 'tools/pathsync-codesigning.cer').read_bytes()).hexdigest().upper() != pin:
        raise ValueError('Public code-signing certificate does not match the application pin.')
    options = ['--force', '--timestamp=none', '--sign', '-' if adhoc else pin]
    if not adhoc:
        store = Path.home() / '.local/share/pathsync-code-signing'
        keychain = Path.home() / 'Library/Keychains/PathSync-code-signing.keychain-db'
        password_file = store / 'keychain-password'
        if not keychain.is_file() or not password_file.is_file():
            raise ValueError('The persistent PathSync signing identity is unavailable. '
                             'Sign the bundle on the signing Mac before packaging a release. '
                             'For local testing only, build with PATHSYNC_SIGNING_MODE=adhoc.')
        if password_file.stat().st_mode & 0o077:
            raise ValueError('The signing keychain password must be accessible only to its owner.')
        result = subprocess.run(['security', 'unlock-keychain', '-p', password_file.read_text(),
                                 str(keychain)], capture_output=True)
        if result.returncode:
            raise ValueError('Could not unlock the dedicated PathSync signing keychain.')
        options += ['--keychain', str(keychain)]
    nested = [(helper, BUNDLE_ID + '.UpdateApply')]
    for name in ('QuickXorHash.dylib', 'OneDriveOAuth', 'OneDriveAuth'):
        path = app / 'Contents/Resources' / name
        if path.exists():
            nested.append((path, BUNDLE_ID + '.' + name.replace('.', '_')))
    for path, identifier in [*nested, (app, BUNDLE_ID)]:
        command = ['/usr/bin/codesign', *options, '--identifier', identifier]
        if not adhoc:
            command += ['--requirements',
                        '=designated => identifier "' + identifier + '" and certificate leaf = H"' + pin + '"']
        subprocess.run([*command, str(path)], check=True)
    verify = ['/usr/bin/codesign', '--verify', '--deep', '--strict']
    if not adhoc:
        verify += ['-R', '=identifier "' + BUNDLE_ID + '" and certificate leaf = H"' + pin + '"']
    subprocess.run([*verify, str(app)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--adhoc', action='store_true', help='temporary local test builds only')
    arguments = parser.parse_args()
    try:
        sign_app(arguments.app, arguments.adhoc)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
