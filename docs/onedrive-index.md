# OneDrive metadata index

Settings → OneDrive metadata index → Connect read-only uses the official rclone
OAuth implementation, pinned to rclone v1.76.0. It requests `Files.Read` and
`offline_access` using rclone’s shared Microsoft application. No Azure directory,
custom Client ID, or browser session is needed after the initial connection.
The permission itself can read file contents; PathSync's Graph index client only
issues metadata GETs and rejects content endpoints and foreign hosts.

Each Mac connects separately. The signed OneDriveAuth helper stores its refresh
token in a device-local macOS Keychain item. The background path disables Keychain
interaction and never starts authorization or opens a browser. Failure requires
reconnecting from Settings. Tokens are passed between helpers only through pipes;
they never enter argv, sync configuration, logs, index databases, or the repository.
Concurrent path groups serialize refreshes with a private lock.

The first run enumerates each configured OneDrive folder and saves a private SQLite
index plus delta cursor beside its merge state. Later runs request the persisted
cursor. Delta application and cursor advancement form one transaction. A partial
response leaves the previous index intact and stops this sync; expired cursors
rebuild the index. Account, root identity, and path changes invalidate the binding.

Local QuickXorHash and SHA256 are computed together and cached against device,
inode, size, mtime, and ctime. QuickXorHash is only an equality optimization; it
never selects a conflict winner or authorizes deletion. Existing SHA256 merge
anchors and protected backups remain in use. Server/mirror metadata disagreement
stops the pair before file mutation so provider lag cannot look like deletion.

Normal automatic sync disables File Provider materialization. Matching server and
local hashes avoid placeholder reads. A changed, unverified placeholder remains
pending; download that particular file in OneDrive before resolving it. Explicit
CLI `--download-online-content` opts into content downloads; previews never do.
Thus zero downloads is guaranteed for the comparison path, not for future real
file transfers initiated by the user or by OneDrive itself.

## Validation scope for 2.18.2

Persistent cursor/cache, failed-page rollback, expired cursors, folder moves and
deletions, changed local fingerprints, unsafe paths, equal placeholders, and stale
provider mirrors have automated regression coverage. The OAuth flow and real
silent token renewal still require the first user-authorized connection on each
Mac. Do not present earlier temporary Graph Explorer benchmark timings as a live
acceptance test of this new login flow.

The prior DeepSight metadata benchmark measured a 62-page initial query at
223.206 seconds; two unchanged incremental checks took 1.450 and 1.372 seconds,
with one Graph request and zero content reads each. These are reference
measurements of the algorithm before this application integration.

The 2.18.1 follow-up removes NSFileCoordinator's implicit materialization from
root exclusion-policy reads. Mac mini sampling reproduced a >180s wait inside its
File Provider access claim despite a resident 1,331-byte policy file. Root policy
reads now disable materialization on the reader thread, reject dataless files,
verify stable inode/size/mtime/ctime snapshots, and return within a 20s deadline.
A timed-out reader holds one slot until it finishes, preventing accumulating
blocked readers. The central OneDrive root policy remains the only authority.

Build requires Go 1.26+ for the pinned OAuth helper dependency, plus macOS command
line tools. No rclone installation is needed on end-user Macs; the signed app
bundles the helper. rclone is MIT licensed; its license accompanies the app.

The first live authenticated check exposed Graph colon entities (`&#x3a;`) whose
File Provider paths contain ordinary colons. Version 2.18.2 prefers exact mirror
names, maps only this observed numeric-colon encoding when the raw name is absent,
and rejects alias collisions transactionally. Unverified mirror paths remain
untouched while independent files can proceed. Any directory deletion or existing
tree conflict containing such a path stays blocked with its anchors retained.
