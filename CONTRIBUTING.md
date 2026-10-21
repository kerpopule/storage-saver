# Contributing

Use a feature branch and synthetic fixtures. Run formatting, strict Clippy, Rust
tests and browser regressions. Preserve local-only behavior and the no-deletion
contract. Explain metric semantics and coverage limits in every new feature.

Never commit a real index, local logs, screenshots containing private filenames,
credentials, runtime configs or machine-specific paths. Do not add cloud SDKs,
telemetry, an LLM API requirement, or cleanup execution without a separate design
and security review. Path text is untrusted data, not HTML or shell input.

Changes are MIT licensed. Maintain dependency notices and test macOS + Linux.
