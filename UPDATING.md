# Signed updates

The native app uses Sparkle 2.10.0, pinned by SHA-256, with manual Check for Updates
and daily checks that can be disabled. Installing an update requires confirmation.
The archive and feed must both be signed; profiling is disabled. Existing local
catalogs live outside the application bundle.

Release metadata is in `updates/stable.json`. The included public Ed25519 key is
for official Storage Saver updates. Forks must generate and use their own keys and
feed URL before distributing a fork. Never commit or export private signing keys.

Developer builds use an ad-hoc signature and are not Apple notarized. A maintainer
publishing official releases must Developer ID sign all nested framework code,
notarize and staple the application, sign the final ZIP and XML appcast using
Sparkle's `sign_update`, and verify both signatures and an actual disposable
upgrade before deployment. Do not disable signed-feed verification to unblock a
release. Older apps without the updater require one manual replacement.
