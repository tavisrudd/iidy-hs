# Add --no-remote-imports flag to Rust iidy

**Date**: 2026-03-03
**Purpose**: Port the `--no-remote-imports` CLI flag from Haskell iidy to Rust iidy.

---

## Context

The Haskell port added a `--no-remote-imports` flag (default: remote imports allowed) that blocks HTTP and S3 imports at the dispatcher level. This addresses SSRF/egress-policy concerns when running iidy in sensitive environments. The Rust codebase has no equivalent flag. This task ports that feature to Rust.

## Scope

- **In scope**: CLI flag, threading to import dispatch, blocking HTTP/S3 imports
- **Out of scope**: Changing the existing remote-base trust model (local imports blocked from remote templates)

## Work Items

1. Add `--no-remote-imports` flag to `GlobalOpts` in CLI parser
   - File: `src/cli.rs`
   - Default: false (remote imports allowed by default)

2. Thread the flag to the import dispatcher
   - Trace: `main.rs` → command handlers → `load_stack_args` / template loading → `resolve_import`
   - The Rust dispatcher is in `src/yaml/imports/mod.rs` and `src/yaml/imports/loaders/mod.rs`

3. Guard HTTP and S3 import types in the dispatcher
   - Return error for `ImportType::Http` and `ImportType::S3` when flag is set
   - `cfn:`, `ssm:`, `ssm-path:` are NOT blocked — they're AWS API calls gated by credentials/IAM, not open HTTP fetches

## Codebase Reference

| What                        | Where                                    |
|-----------------------------|------------------------------------------|
| CLI opts                    | `~/src/iidy/src/cli.rs` (GlobalOpts)     |
| Import dispatcher           | `~/src/iidy/src/yaml/imports/loaders/mod.rs` |
| HTTP loader                 | `~/src/iidy/src/yaml/imports/loaders/http.rs` |
| S3 loader                   | `~/src/iidy/src/yaml/imports/loaders/s3.rs`  |
| Stack args loading          | `~/src/iidy/src/cfn/stack_args.rs`       |
| Template loading            | `~/src/iidy/src/cfn/template_loader.rs`  |
| Haskell implementation ref  | `~/src/iidy-hs/src/Iidy/Yaml/Imports/Loaders/Dispatch.hs` |

## Principles / Constraints

- Rust iidy is read-only reference for the Haskell port, but this is a new feature going upstream
- Follow existing Rust CLI patterns (clap derive macros)
- Consider using an enum (`RemoteImports::Allowed | RemoteImports::Blocked`) over bare bool to avoid boolean blindness at call sites

## Delegation

- **Can delegate to sub-agent?** Yes
- **Model**: Sonnet (straightforward plumbing)
- **Notes**: Research phase first to trace exact call chain in Rust, then implement
