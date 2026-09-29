# Publishing an in-app update

PathSync accepts an in-app update only when the release contains the architecture-specific ZIP and its matching `.zip.sig` asset. The app verifies the archive with the public Ed25519 key embedded in `UpdateInstaller.swift` before extracting or replacing the application.

The private key is kept outside this repository at `~/.local/share/pathsync-release-signing/ed25519.key`. Preserve it securely; a replacement key requires a new app build with a new embedded public key and a manual transition. Never commit the private key.

For each release, update both version fields in `Info.plist`, build the app, create `PathSync-vVERSION-macOS-ARCH.zip` with `ditto -c -k --sequesterRsrc --keepParent`, run `swift tools/sign-release.swift sign ARCHIVE`, and publish both the ZIP and `.zip.sig` as GitHub Release assets. Run `tests/UpdateInstallChecks.swift` against the final archive and signature before publishing.

The app uses the macOS login-item service for launch at login. Users can enable it in Settings → General; it is independent of the per-user `launchd` sync schedule.
