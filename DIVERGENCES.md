# Known Divergences: iidy-hs vs iidy (Rust)

This document lists all intentional or framework-imposed behavioral differences
between the Haskell port (iidy-hs) and the Rust original (iidy).

## CLI Help Formatting

**Cause**: clap (Rust) vs optparse-applicative (Haskell) — different formatting libraries.

- Slightly different flag/argument layout in `--help` output
- clap auto-generates `--no-X` variants for boolean flags; optparse-applicative uses explicit `flag True False`
- All content (command names, descriptions, flag names) is identical

## YAML Serialization in Snapshots

**Cause**: serde_yaml vs custom HsYAML emitter.

Two Rust test snapshots (`handlebars-in-tags`, `yaml-11-booleans`) use serde_yaml's
internal serialization format which differs from actual CLI output. Our emitter
produces correct YAML tag syntax (e.g., `!Ref` tags). Both ports produce
identical output when run as CLI commands — the snapshot difference is a
test artifact in the Rust codebase.

## Shell Completion Scripts

**Cause**: clap_complete generates scripts dynamically; Haskell uses hardcoded scripts.

- PowerShell completion is not supported (Rust supports it via clap_complete)
- Completion script content may differ in edge cases (both support bash, zsh, fish)
- Default shell detection: both read `$SHELL` env var when no shell argument given

## Error Display: stderr vs stdout TTY Check

**Cause**: Intentional improvement in Haskell.

Error color detection checks `stderr` TTY status in Haskell (since errors are
printed to stderr), while Rust checks `stdout`. The Haskell behavior is arguably
more correct — if stderr is piped to a file but stdout is a TTY, errors should
not contain ANSI codes since they'll end up in the file.

## Explain Command: More Permissive Input

**Cause**: Intentional Haskell improvement.

The `explain` command accepts multiple input formats:
- `ERR_2001` (standard, same as Rust)
- `err_2001` (case-insensitive, Haskell addition)
- `2001` (digits only, auto-prefixed, Haskell addition)

Rust only accepts the `ERR_NNNN` format.

## FORCE_COLOR Environment Variable

Both Rust and Haskell respect the `FORCE_COLOR` env var to force colored output
even when not connected to a TTY. Both also respect `NO_COLOR` with higher
priority (NO_COLOR > FORCE_COLOR > TTY check).

## AWS API Pagination (Untestable Offline)

Event pagination for `describe-stack` and `list-stacks` uses AWS SDK pagination.
Both implementations fetch events and paginate, but exact pagination behavior
cannot be verified without live AWS API calls. Verified by code review.

## Live AWS Operations (Untestable Offline)

The following behaviors require live AWS and are verified by code review only:
- Stack creation/update/deletion actual API behavior
- S3 upload/download for template approval
- SSM parameter read/write operations
- Real terminal spinner animation timing
- Live polling loop behavior with real CloudFormation events
- Network NTP time synchronization
