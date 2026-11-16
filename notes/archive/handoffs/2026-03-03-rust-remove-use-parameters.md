# Remove --use-parameters from Rust iidy lint-template

**Date**: 2026-03-03
**Created by**: 2026-03-03--15 (`d3cd2d47-d402-4e5b-a325-03c863a63463`)
**Purpose**: Remove dead `--use-parameters` flag from Rust `lint-template` CLI and docs.

---

## Context

The `lint-template --use-parameters` flag originated in the JS iidy, where it told `laundry-cfn` (a local CloudFormation linter) to include stack parameter values during linting. Both the Rust and Haskell ports replaced `laundry-cfn` with the AWS `ValidateTemplate` API, which does not accept parameters — making the flag dead code.

The Haskell port has already removed it (commit 3d9af2a). The Rust port still defines and parses the flag but never reads the value.

## Work Items

1. **Remove the flag from `src/cli.rs`** (~line 662-663)
   - Delete the `use_parameters: bool` field from `LintTemplateArgs`
   - Delete the `#[arg(long = "use-parameters")]` annotation

2. **Update `docs/command-reference.md`** (~lines 661-672)
   - Remove the paragraph about `--use-parameters` being accepted for compatibility
   - Remove the `--use-parameters` row from the options table

3. **Check for any references** to `use_parameters` in `src/` and tests — remove if found (likely none, since the value was never read)

## Codebase Reference

| What                  | Where                              |
|-----------------------|------------------------------------|
| CLI arg definition    | `~/src/iidy/src/cli.rs:662-663`    |
| Docs mentioning flag  | `~/src/iidy/docs/command-reference.md:661-672` |

## Principles / Constraints

- The `~/src/iidy/` repo is read-only from iidy-hs sessions. This task must be done in the Rust repo directly.

## Delegation

- **Can delegate to sub-agent?** Yes
- **Model**: Sonnet
- **Notes**: Straightforward deletion, no design decisions needed.
