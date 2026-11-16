# Rust Compatibility Reference

Comparison between the Haskell port (iidy-hs) and the Rust implementation (iidy).

## Overview

iidy-hs is a feature-identical port of the Rust iidy CloudFormation
preprocessor/deployer. The port covers all 22 CLI commands, produces the same
output format, and matches error messages character-for-character.

Key compatibility metrics:

- **37/37** render snapshot comparisons pass (YAML output, stack events, etc.)
- **49/49** error snapshot comparisons pass (error codes, messages, formatting)
- **851** automated tests (unit, property, integration)
- **86** Haskell modules porting **96** Rust modules (~16,600 Rust LOC)

The two binaries are intended to be drop-in replacements for each other. Any
behavioral difference not listed in the Known Divergences section below is
considered a bug.

---

## Library Differences

| Domain | Rust Crate | Haskell Equivalent | Notes |
|---|---|---|---|
| CLI parsing | `clap` + `clap_complete` | `optparse-applicative` | Subcommands, flags, shell completions (bash/zsh/fish) |
| YAML parsing | `tree-sitter-yaml` | HsYAML event API | Pure Haskell YAML 1.2; event-level API gives line/column positions |
| YAML output | `serde_yaml` | Custom OValue + emitter | Preserves key insertion order; correct YAML tag syntax |
| JSON | `serde` + `serde_json` | `aeson` | Standard JSON library in both ecosystems |
| JMESPath | `jmespath` crate | Custom implementation (~600 LOC) | No maintained Haskell JMESPath library exists |
| Handlebars | `handlebars` crate | Custom implementation | Supports helpers (`toYaml`, `toJson`, etc.) and block helpers |
| JSON Schema | `jsonschema` (Draft 7) | Custom Draft 7 validator (~170 LOC) | Covers all keywords iidy uses for parameter validation |
| NTP time sync | `ntp` crate | Custom SNTP client (~100 LOC) | No maintained Haskell NTP library; custom UDP-based implementation |
| Async runtime | `tokio` | Plain IO + `forkIO` | GHC green threads; no async runtime needed |
| AWS SDK | `aws-sdk-rust` | `amazonka` 2.0 | 7 service packages: CloudFormation, S3, SSM, STS, KMS, SNS, core |
| Terminal colors | `owo-colors` + `anstyle` | `ansi-terminal` | ANSI SGR codes, 256-color support |
| Diff | `similar` | Custom diff | Used for template approval display |
| Snapshot tests | `insta` | `tasty` + custom snapshot scripts | Shell scripts compare against Rust snapshot files |
| Regex | `regex` | `regex-tdfa` | POSIX extended regex |
| Hashing | `sha2` + `base64` | `cryptohash-sha256` + `base64-bytestring` | SHA-256 for template hashing |
| PTY (demo) | `portable-pty` | `posix-pty` | POSIX only (no Windows PTY support) |
| Logging | `log` + `env_logger` | Direct stderr output | Structured output via OutputDispatch pipeline |
| Time | `chrono` | `time` (base) | Date/time parsing, formatting, duration arithmetic |

---

## Known Divergences

All known behavioral differences between the two implementations. Anything not
listed here should be considered a bug in iidy-hs.

### CLI Help Formatting

**Cause**: clap (Rust) vs optparse-applicative (Haskell).

- Slightly different flag/argument layout in `--help` output
- clap auto-generates `--no-X` variants for boolean flags; optparse-applicative
  uses explicit `flag True False`
- All content (command names, descriptions, flag names) is identical

### YAML Serialization in Test Snapshots

**Cause**: serde_yaml vs custom HsYAML emitter.

Two Rust test snapshots (`handlebars-in-tags`, `yaml-11-booleans`) use
serde_yaml's internal serialization format, which differs from actual CLI
output. The Haskell emitter produces correct YAML tag syntax (e.g., `!Ref`
tags). Both ports produce identical output when run as actual CLI commands. The
difference is a test artifact in the Rust codebase.

### Shell Completion Scripts

**Cause**: clap_complete generates scripts dynamically; Haskell uses hardcoded scripts.

- PowerShell completion is not supported (Rust supports it via clap_complete)
- Completion script content may differ in edge cases
- Both support bash, zsh, and fish
- Both read `$SHELL` env var when no shell argument is given

### Error Color Detection: stderr vs stdout

**Cause**: Intentional improvement in Haskell.

Error color detection checks `stderr` TTY status in Haskell (since errors are
printed to stderr), while Rust checks `stdout`. The Haskell behavior is more
correct: if stderr is piped to a file but stdout is a TTY, errors should not
contain ANSI codes since they end up in the file.

### Explain Command: More Permissive Input

**Cause**: Intentional Haskell improvement.

The `explain` command accepts multiple input formats:
- `ERR_2001` -- standard, same as Rust
- `err_2001` -- case-insensitive (Haskell addition)
- `2001` -- digits only, auto-prefixed (Haskell addition)

Rust only accepts the `ERR_NNNN` format.

### AWS API Pagination and Live Operations

Event pagination for `describe-stack` and `list-stacks` uses SDK pagination
helpers. Exact pagination behavior, along with stack CRUD operations, S3
upload/download, SSM parameter read/write, spinner timing, live polling, and
NTP sync, cannot be verified without live AWS. Verified by code review only.

---

## Architecture Differences

### OValue Type for Key Order Preservation

Rust's serde_yaml preserves YAML key order via `IndexMap`. Haskell's aeson
`Object` uses unordered `HashMap`. iidy-hs defines a custom `OValue` type with
`OObject [(Text, OValue)]` to preserve insertion order through all YAML
processing, template expansion, and output emission.

### Plain IO Monad Stack (No Async Runtime)

Rust uses `tokio` async with `Result<T, Error>` threading. The Haskell port
uses plain `IO` with a `CfnContext` record passed explicitly (no `ReaderT`,
`StateT`, or monad transformer stack). GHC's built-in green threads handle
concurrency; spinner animation and polling timeouts use `forkIO` with
`MVar`/`IORef` for synchronization. Errors use `Control.Exception`.

### amazonka DuplicateRecordFields

amazonka 2.0 uses `DuplicateRecordFields`, making field selectors ambiguous.
The port imports operation-specific modules with unique qualifiers and uses
`OverloadedRecordDot` for reading fields from known-typed values. This is a
Haskell-specific ergonomic concern with no Rust equivalent.

### Test Organization

Rust uses per-module test files with `insta` snapshot testing. The Haskell port
uses a single test driver (`test/Spec.hs`) with `tasty` test groups, plus
custom shell scripts that compare rendered output against the Rust snapshot
files directly.

### Output Pipeline

Both implementations use a dispatcher pattern for output. Rust uses trait
objects (`dyn OutputRenderer`). Haskell uses an `OutputDispatch` record of
callback functions, with `InteractiveRenderer` and `JsonRenderer`
implementations selected at startup based on `--output json`.

---

## Verification

### Render Snapshot Comparison

`scripts/snapshot-compare.sh` runs all 37 render fixtures through the Haskell
binary and compares output against the corresponding Rust `insta` snapshot
files in `~/src/iidy/tests/snapshots/`. Differences are reported as diffs.

### Error Snapshot Comparison

`scripts/error-snapshot-compare.sh` runs all 49 error fixtures and compares
the formatted error output (error codes, messages, hints, context) against
Rust snapshots. This covers all error display paths including multi-line
errors, validation errors, and AWS error wrapping.

### Automated Tests

851 tests cover:
- Unit tests for all pure functions (YAML processing, template expansion,
  JMESPath evaluation, JSON Schema validation, Handlebars rendering)
- Property tests (round-tripping, invariants)
- Integration tests for the output pipeline (all 26 OutputData types through
  both renderers)
- Mock-based AWS tests (no real API calls)

### Live AWS Verification (Phase 14)

All 22 commands will be tested against real AWS infrastructure to verify:
- API call correctness and error handling
- Polling behavior with real CloudFormation events
- Spinner timing and terminal output
- Auth chain (profiles, assume-role, region defaults)
