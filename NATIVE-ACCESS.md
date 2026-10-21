# Standalone app and agent access

Build with `cargo build --release --locked` then `python3 scripts/build_macos.py`.
The result is `target/macos/StorageSaver.app`: a native AppKit window, embedded
WebKit interface and bundled Rust engine. It does not open a browser, require
Node at runtime or host a public website. A private loopback engine also supports
the human/AI shared index and background refresh. New installs use
`scripts/install_macos.py --binary target/release/storage-atlas` after building.
The installer refuses existing targets. Existing catalog migrations need an
explicit preservation check. Local signatures are ad-hoc, not notarized.

## Invite and grant

The left-side Invite an agent button produces copy-paste CLI instructions for
any harness on the same computer or an independently authorized shell. It does
not tunnel files or transfer machine credentials. The default invitation is
index-only. Do not paste a file-access token into a public or untrusted harness.

Allow ordinary access and Allow elevated access open native folder selectors.
Choose View or Edit, then acknowledge the risk notice. Select only required data
folders, including both source and destination when authorizing backup or moves.
Grants last 30 minutes, require the app to stay open and can be revoked using
Manage permissions. No grants are created by the inventory website/API.

View permits list, stat and reads of up to 32 KiB. Edit additionally permits
new files/folders, verified copies up to 1 GiB per request, non-overwriting
same-volume file moves and replacement of small UTF-8 text up to 32 KiB.
Replacement requires the current SHA-256 and retains the old file at the returned
backup path. The protocol does not recursively delete, overwrite destinations,
move across volumes or silently bypass protected paths. A harness can copy a
directory as separate scoped operations; a partial directory backup is not complete.

Elevated mode is not blanket root access. One macOS administrator authorization
at grant creation opens a scoped helper session. Subsequent in-scope requests do
not reopen native confirmation or authentication. The helper exits on revocation,
app disconnect or expiry and never silently renews. Ordinary permission failures,
FDA and media consent are distinct. Native admin-prompt acceptance still needs a
human; headless policy/root-helper tests do not prove that GUI consent was given.

The warning assigns users responsibility for choosing scopes and authorized
actions and keeping verified backups. It does not guarantee safety, waive
permission checks or constitute a legal opinion about liability.

## Accounting

The old `allocated` fields are replaced at the API boundary by explicit
`referenced_file_blocks_bytes`; legacy catalogs stay intact. Physical values are
null until measured. Category bars show file counts, not an inflated disk pie.
Use `storage-saver measure /selected/path --json`, or Inspect then Measure
physical data. Actual data extents are unioned per device, including diverged
clones, sparse data and hardlinks. Physical block padding is accounted for.

Measurements have file/time/extent limits. Unsupported compression, fork mismatch,
permissions, concurrent file changes or budget exhaustion keep the physical total
unknown. A complete measured data footprint excludes filesystem metadata and is
not reclaimable space: snapshots and references outside the selection may retain
blocks. No proportional normalization, volume-size clamping or guessed clone
subtraction is used.
