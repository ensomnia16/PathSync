# Publishing an in-app update

PathSync accepts an in-app update only when the release contains the architecture-specific ZIP and its matching `.zip.sig` asset. The app verifies the archive with the public Ed25519 key embedded in `UpdateInstaller.swift` before extracting or replacing the application.

The private key is kept outside this repository at `~/.local/share/pathsync-release-signing/ed25519.key`. Preserve it securely; a replacement key requires a new app build with a new embedded public key and a manual transition. Never commit the private key.

The macOS application and its update helper use the persistent certificate in
`tools/pathsync-codesigning.cer`. Its fingerprint is pinned in
`CodeSigningIdentity.swift`. The private identity stays in the signing Mac's
dedicated `PathSync-code-signing.keychain-db` keychain. The default build uses
`tools/sign-app.py` and fails if that identity is unavailable. It never generates
a replacement certificate. `PATHSYNC_SIGNING_MODE=adhoc ./build.sh OUTPUT` is
available for local development.

For a signed release, set `PATHSYNC_AUTH_HELPER` to the original signed
`Contents/Resources/OneDriveAuth` from the verified v2.19.2 release if the
installed copy does not match. The build copies it byte for byte and builds
`OneDriveAuthGate` separately. The signing tool verifies the helper's pinned
certificate and CDHash and leaves its signature intact. The macOS login
keychain partition list can bind an existing approval to this exact CDHash.
A rebuild with the same certificate is not sufficient.

Both update verification and the replacement helper require the pinned
certificate and application identifier. The designated requirement stays the
same across builds. The first transition from an ad-hoc build requires one
macOS permissions approval for the new identity.

For each release, update both version fields in `Info.plist`, build the app, create `PathSync-vVERSION-macOS-ARCH.zip` with `ditto -c -k --sequesterRsrc --keepParent`, run `swift tools/sign-release.swift sign ARCHIVE`, and publish both the ZIP and `.zip.sig` as GitHub Release assets. Run `tests/UpdateInstallChecks.swift` against the final archive and signature before publishing.

The app uses the macOS login-item service for launch at login. Users can enable it in Settings → General; it is independent of the per-user `launchd` sync schedule.
