# Security policy

Storage Saver is a private desktop app with a Rust metadata index, a loopback
read-only inventory API and a separate, capability-gated native file broker.
The index itself does not read file contents or authorize cleanup. Filenames,
indexes, audit logs and invitations with access tokens are private.

The HTTP service binds loopback, rejects foreign Host/Origin values, has no CORS
grants and escapes filenames. It exposes no file mutation or grant-creation API.
It is not authenticated against other local processes. Never expose it remotely.

Only the native UI creates file grants after folder selection and acknowledgment.
View and edit, ordinary and elevated, are separate choices. Grants are in memory,
expire after 30 minutes and disappear on quit or revoke. The local Unix socket
is 0600, checks the peer UID and requires an unpredictable per-grant token.
This is not isolation from malicious software already controlling the OS account.

Operations use descriptor-relative no-follow traversal, retained folder identities,
known credential/system-path denials and action checks. Copies are hash-verified
and never overwrite; moves are same-volume and non-overwriting. Small text
replacement requires an expected SHA-256 and retains the prior file as a backup.
No permanent-delete operation is exposed. Bounds and remaining risks are in
`NATIVE-ACCESS.md`. Revocation stops new requests, not an already running action.

Elevated requests require a native per-operation confirmation and macOS admin
authorization. Only the fixed scoped helper is invoked, never an agent-provided
shell. No admin password or unrestricted sudo is delegated. The helper has a
45-second fail-stop limit. Cancellation/failure is not proof of zero side effects;
an interrupted new copy may need inspection. Root does not bypass FDA, SIP or
media-library consent. No TCC edits are performed.

Physical accounting never substitutes file-block sums for measured usage. Missing
or inconsistent extent mappings return unknown. Data extent unions are not a
promise of deletion savings, because other references and snapshots can retain data.

Report vulnerabilities with disposable fixtures, never real indexes or tokens.
