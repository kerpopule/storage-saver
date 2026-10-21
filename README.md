# Storage Saver

**A private, local-first storage observatory for people and agents.**

Rust indexes metadata and measures shared data extents. A standalone macOS
AppKit/WebKit app presents the same private index as the JSON CLI. The left-side
agent invitation and native scoped-access controls are described in [NATIVE-ACCESS.md](NATIVE-ACCESS.md).
No cloud storage, telemetry, file-content uploads, account, or AI API key required.
Official builds contact StorageSaver.app for signed update checks and downloads.

[Website](https://www.storagesaver.app) · [Source](https://github.com/kerpopule/storage-saver)

**MIT licensed:** use, modify, redistribute and sell it, preserving the license
notice. The software is provided without warranty. See [LICENSE](LICENSE) and
[third-party notices](THIRD_PARTY.md).

## What it does

- Indexes readable regular files, directories and symlink metadata on one filesystem.
- Separates file length, file-block references, measured physical data and live capacity.
- Counts shared APFS extents once when measured; leaves unsupported totals unknown.
- Drills into folders, finds large files, searches paths and groups storage categories.
- Tracks directory growth across scheduled snapshots (largest 5,000 directories at
  least 100 MB, retained for 90 days).
- Finds **same-size duplicate leads**, not content-verified duplicates.
- Produces review dossiers with identity checks, protection signals and next checks.
- Keeps the last completed index available during a new scan; a single-writer lock
  prevents overlapping scanners.
- Updates live capacity every five seconds; rebuilds the index on a configurable
  schedule, default six hours after the last completed scan. Manual refresh is available.

**The index does not authorize cleanup.** Dossiers are planning levers, not grants.
Separately scoped native grants permit verified copies, moves and bounded edits,
with a risk acknowledgment; no permanent-delete operation is exposed. Build outputs can contain unique work. A cache can back a live service.
A model can be irreplaceable. Neither a category nor a dossier authorizes deletion.

## Build & run

Rust stable (edition 2024), a C compiler for bundled SQLite, macOS or Linux.
The native bundle includes its engine and interface; Node is not required at runtime.
Build the desktop bundle with `python3 scripts/build_macos.py` after the Rust build.
The loopback `serve` command below is for engine development and CLI integration,
not the standalone-app entry point.

```sh
cargo build --release --locked
./target/release/storage-atlas --root "$HOME" scan
./target/release/storage-atlas --root "$HOME" serve
# Open http://127.0.0.1:43127
```

`serve` scans if the index is missing or overdue, then refreshes it periodically.
Ctrl-C stops the foreground process group. Scanners always run in a separate
process, including ordinary unprivileged scheduled refreshes. A dedicated scan
watchdog exits with code 124 after 120 seconds without traversal progress, or
30 minutes without completion during SQLite finalization. It retains the previous
complete index and reports failure rather than pretending elevated coverage finished.
It does not dismiss OS prompts, change privacy settings, or skip stalled content
silently. Interrupted construction never replaces a completed index. Restarting
resumes with a fresh scan, not a partially committed tree.
The scanner is single-threaded. Memory grows with directory ancestors, multi-link
inode identities and SQLite index sorting. Disk I/O and metadata enumeration often
dominate runtime. The full-path catalog can be large on machines with millions of
files: budget roughly a kilobyte per entry, and room for **both** the old catalog
and a newly built one. The UI exposes its own private state footprint in Coverage.
The catalog is excluded from its inventory, not hidden from the live free-space meter.

Default scope is `/System/Volumes/Data` on macOS, `/` on Linux. Traversal stays on
one filesystem and does not follow symlinks. Mounted/network/external volumes require
a separate explicit root and **separate data directory**. The macOS Data root avoids
counting the same user files through firmlinks twice. It does not include the sealed
system volume. Linux `/proc`, `/sys`, `/dev` and other mounts are not traversed.
The dashboard must run as the normal user and refuses to listen as root.
For approved broader metadata coverage, `serve --elevated-scan` uses **existing
non-interactive sudo permission** to start a scan-only child; it never edits sudoers,
installs a setuid helper or elevates the HTTP service. Generated state files remain
private and readable by the invoking user. The opt-in privilege test is documented below.

Root is not Full Disk Access. On macOS grant **the installed Storage Saver.app**
Full Disk Access in System Settings → Privacy & Security, then refresh the index.
The native executable owns the desktop window; its bundled Rust engine scans. The
installer gives this locally built bundle an ad-hoc signature, not Developer ID
signing or notarization. An updated ad-hoc build may require renewing the grant.
OS consent, SIP and protected system vaults are never bypassed. Remaining failures
are reported; metadata enumeration does not read the contents of protected files.

```sh
# Keep each scope's index distinct
storage-atlas --root /Volumes/Archive --data "$HOME/.local/share/atlas-archive" scan
storage-atlas --root /Volumes/Archive --data "$HOME/.local/share/atlas-archive" serve --port 43128
```

Default state: `$XDG_DATA_HOME/storage-atlas`, otherwise
`$HOME/.local/share/storage-atlas`. Use global `--data PATH` to override it.
This is private runtime data, **never source code**. Index directory permissions
are 0700. The binary sets umask 077. Indexes contain sensitive filenames even though
the metadata index does not read contents. Native file grants are a separate,
explicitly authorized content-access path. Keep all private state off public systems.

## Compatibility and installed identity

The product and dashboard are **Storage Saver**, with intended website
**StorageSaver.app**. The macOS installer exposes `storage-saver` plus a
`storage-atlas` compatibility alias. The internal Rust crate/binary, LaunchAgent
identifier, bundle identifier and state directory retain their original names to
avoid losing an existing catalog or changing permission identity unnecessarily.
An existing development installation may retain the `Storage Atlas.app` bundle
path while displaying Storage Saver. An update must disclose that an ad-hoc
signature can require renewed Full Disk Access; no permission is migrated silently.

## CLI for people and agents

```sh
storage-atlas capacity --json
storage-atlas progress --json
storage-atlas status --json
storage-atlas browse /absolute/indexed/folder --json
storage-atlas top --kind dirs --limit 25 --json
storage-atlas top --kind files --query weights --json
storage-atlas top --kind candidates --json
storage-atlas search 'node_modules' --limit 40 --offset 0 --json
storage-atlas growth --json
storage-atlas duplicates --json
storage-atlas plan /absolute/indexed/path --json
storage-atlas serve --interval 21600 --port 43127
```

Global options can appear before or after the command. Lists are capped at 500
rows, paginated with `limit`, `offset`, and exact `has_more`. Errors are nonzero;
`--json` emits runtime errors as JSON to stderr (Clap syntax errors retain its help
format). Default human output is formatted JSON, intentionally inspectable and copyable.
Treat dossiers as review-only data. See the safety contract above before making
any reclaim decisions; no JSON result grants deletion authority.

## Understanding the numbers

**Free space is the truth about room available now.** It is sampled from statvfs,
not calculated by adding file sizes. The UI labels total minus available as
“unavailable”; OS-reserved space can be part of it.

- Logical bytes: file length. Sparse files can have huge lengths and few blocks.
- Counted allocation: `st_blocks × 512`. Regular hardlinks are charged once per
  device/inode; the alias path has zero charged bytes. Ownership among aliases
  follows traversal order and is not an attribution guarantee.
- APFS clones/shared extents may be charged to multiple files. Summed allocation
  is **not** physical unique usage or guaranteed reclaimable space.
- Nested directory totals overlap. Never sum ranked parents and children.
- Directory metadata, snapshots, inaccessible files, other mounted volumes and
  filesystem bookkeeping are not all represented. No reconciliation is invented.
- Live files can change during enumeration. This is not an atomic filesystem
  snapshot. Dossiers only recheck top-level identity/size/mtime; descendants and
  active usage must be audited separately before any approved external action.
- Category/protection signals are filename/path heuristics, not ownership proofs.
- Non-UTF-8 paths that cannot be addressed safely are reported as gaps, not silently
  merged under replacement characters. Only the first 40 error examples are kept.
- Growth needs two completed scans. Newly created/removed folders may be outside
  the retained top-directory intersection. Directory mtime is not last-use time.

## Local background app on macOS

```sh
python3 scripts/install_macos.py --binary target/release/storage-atlas
```

Installs a native `Applications/Storage Saver.app` bundle with the Rust executable,
a CLI wrapper, an original icon, and a new per-user LaunchAgent. It binds **only 127.0.0.1**, opens no public
port and changes no existing service. It refuses to overwrite unrelated targets.
The installer prints exact installed paths and start/stop commands.
Add `--elevated-scan` only when elevated scanning is approved and non-interactive
sudo is already available. `--no-start` installs without loading the new service. The service
continues until stopped; this is an intentionally installed app, not a test preview.
A local process running as your user can query the loopback API. It is not a
multi-user security boundary. For Linux, run `serve` under your own user service
manager; no root daemon or automatic installer is provided.

## Development & quality

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test --locked
# Browser regressions use an optional Playwright dependency:
npm ci
npm run test:ui
# Optional, explicit sudo integration test. Synthetic fixture only:
python3 tests/elevation.py --binary target/release/storage-atlas --sudo
```

The browser runner owns its temporary fixture, service, browser and shutdown.
It exercises synthetic paths only. Local real-machine screenshots/receipts belong
in ignored `.local/`, not a public issue or commit. GitHub Actions checks Rust on
macOS and Linux and UI regressions on Linux. Test execution does not publish anything.

## Security & limitations

Read [SECURITY.md](SECURITY.md). Loopback binding, strict Host/Origin checks,
no CORS, no-store responses, CSP, no shell endpoints, and text-only DOM rendering
reduce common local-dashboard risks. These controls do not protect an already
compromised user account. There is no deletion API or LLM agent with write access.
Realtime FSEvents/inotify indexing, content-hash deduplication,
service ownership discovery, automatic cleanup execution and multi-volume aggregation are
**not implemented**. This release favors accurate boundaries over destructive magic.

MIT licensed. Dependency licenses and notices: [THIRD_PARTY.md](THIRD_PARTY.md).
