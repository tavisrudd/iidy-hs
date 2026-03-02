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

## describe-stack Event Pagination

**Cause**: Intentional optimization with conditional pagination.

Both implementations use single-page event fetches for polling loops (new events
always appear on the first page). For `describe-stack --events N`, Rust paginates
up to `N * 2` events to ensure the requested count is satisfiable. Haskell now
does the same via `fetchStackEventsUpTo`. The `list-stacks` command paginates
fully in both implementations.

## Drift Detection Polling Timeout

**Cause**: Intentional safety improvement in Haskell.

Rust polls `DescribeStackDriftDetectionStatus` indefinitely with no timeout.
Haskell adds a configurable safety cap (default: 100 iterations x 3s = 5 minutes)
to prevent infinite hangs on stuck drift detections. Emits a `LevelWarning`
status update if the cap is reached and proceeds with potentially incomplete
results. Constants are in `DescribeStackDrift.hs` (`driftPollMaxIterations`,
`driftPollIntervalSecs`).

**TODO**: Fix Rust to also have a timeout cap.

## Terminal Status List: UPDATE_FAILED Bug (Fixed in Haskell)

**Cause**: Bug in Rust iidy (inherited from iidy-js, then fixed in iidy-js).

The Rust port (`is_terminal_status.rs`) does NOT include `UPDATE_FAILED` in
its terminal status list, which is correct — CloudFormation auto-initiates
rollback after `UPDATE_FAILED`, so the polling loop must continue until
`UPDATE_ROLLBACK_COMPLETE` or `UPDATE_ROLLBACK_FAILED`. iidy-hs matches this.

However, an earlier iidy-hs bug DID include `UPDATE_FAILED`, which would have
caused premature polling termination. Fixed 2026-03-01.

Source of truth: `iidy-js/src/cfn/statusTypes.ts` (14 terminal statuses).
See `Context.hs` for detailed provenance documentation.

**TODO**: Audit Rust terminal status list against iidy-js to confirm full
alignment (DELETE_SKIPPED, REVIEW_IN_PROGRESS presence).

## Live AWS Operations (Untestable Offline)

The following behaviors require live AWS and are verified by code review only:
- Stack creation/update/deletion actual API behavior
- S3 upload/download for template approval
- SSM parameter read/write operations
- Real terminal spinner animation timing
- Live polling loop behavior with real CloudFormation events
- Network NTP time synchronization
