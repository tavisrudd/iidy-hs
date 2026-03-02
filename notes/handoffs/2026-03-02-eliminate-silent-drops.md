# Eliminate Silent Drops — Russell -7/-8 Findings

**Date**: 2026-03-02
**Prior session**: Session 46 — all handoff chunks complete, Russell review done
**Strategy**: Fix the systemic pattern identified by the Russell review: IO boundaries that silently accept bad input

---

## Context

The Rusty Russell API review (notes/2026-03-02-russell-review.md) found a clear pattern:
the pure core scores +7 to +9 but IO boundaries score -8 to -7. Six findings at -7 share
the same root cause: **the API accepts input and silently does the wrong thing.**

Session 46 already fixed 3 of the 20 findings (#1 OnFailure ADT, #5 oIsTruthy, #6 TemplateLoader
Either). This session targets the remaining silent-drop findings.

**Current state**: 1091 tests, zero warnings.

---

## What to Do

### Chunk A: `param get --format json` silently ignored (Russell #19, rating -8)

The `--format json` flag is parsed into a `ParamFormat` ADT but the command implementation
ignores it and always outputs raw text. Either implement structured JSON output or reject
the flag values at parse time.

1. Read `src/Iidy/Ssm/Params.hs` — find the `param get` implementation
2. Read `src/Iidy/Cli.hs` — find ParamFormat and how --format is parsed for param commands
3. Decision: implement JSON output OR reject at parse time with a clear error
4. Add tests
5. Run `cabal test`

**Files**: 2-3 (`Params.hs`, `Cli.hs`, test file)
**Risk**: Low. User-visible behavior change but currently broken anyway.

### Chunk B: `--context` flag accepted but never applied (Russell #20, rating -6)

The `--context` flag for template-approval is parsed and stored but never used to trim diffs.

1. Read `src/Iidy/Cfn/Operations/TemplateApproval.hs` — find where diff is generated
2. Either implement context-line trimming or remove the flag from the parser
3. Add tests
4. Run `cabal test`

**Files**: 1-2 (`TemplateApproval.hs`, possibly `Cli.hs`)
**Risk**: Low.

### Chunk C: `getStrList` silently drops non-string elements (Russell #3, rating -7)

`getStrList` in StackArgsLoader filters out non-string elements instead of erroring.
A user writing `capabilities: [CAPABILITY_IAM, 123]` silently loses `123`.

1. Read `src/Iidy/Cfn/StackArgsLoader.hs` — find `getStrList`
2. Change to error on non-string elements with a clear message
3. Add test for mixed-type list rejection
4. Run `cabal test`

**Files**: 1-2 (`StackArgsLoader.hs`, test file)
**Risk**: Low. Could surface errors for users with bad configs, but that's the point.

### Chunk D: Unknown YAML keys in stack-args silently ignored (Russell #10, rating -7)

Typos in stack-args.yaml keys (e.g., `capabilties` instead of `capabilities`) are silently
ignored. The parser should warn or error on unrecognized keys.

1. Read `src/Iidy/Cfn/StackArgsLoader.hs` — understand which keys are valid
2. After parsing all known keys, check for remaining unknown keys
3. Error with a message listing the unknown keys and suggesting corrections
4. Add tests for unknown key rejection
5. Run `cabal test`

**Files**: 1-2 (`StackArgsLoader.hs`, test file)
**Risk**: Medium. Could break configs that have non-standard keys. Check Rust behavior first.

### Chunk E: `getStackName` falls back to "unnamed-stack" (Russell #2, rating -7)

When `saStackName` is `Nothing`, `getStackName` returns `"unnamed-stack"` — a default that
is never correct and will cause confusing AWS errors.

1. Read `src/Iidy/Cfn/RequestBuilder.hs` — find `getStackName`
2. Change to return `Either Text Text` or error early
3. Fix callers to handle the missing-name case explicitly
4. Add test
5. Run `cabal test`

**Files**: 2-3 (`RequestBuilder.hs`, callers, test file)
**Risk**: Low. "unnamed-stack" was never a correct fallback.

### Chunk F: Dot-path query returns ONull on miss (Russell #11, rating -7)

`applyDotQueryValidated` returns `ONull` when a path component doesn't exist, which
silently propagates as null through templates.

1. Read the resolver — find `applyDotQueryValidated`
2. Consider: should it error, or is ONull-on-miss intentional for `!$ foo.bar.baz`?
3. Check Rust behavior — does it also return null on miss?
4. If Rust errors: fix to match. If Rust returns null: document as intentional.
5. Add tests either way.

**Files**: 1-2 (resolver, test file)
**Risk**: Medium. Changing null-on-miss to error could break valid templates.

---

## What NOT to Do Yet

- `try @SomeException` narrowing (#17) — needs per-site audit, 15+ call sites
- Terminal status string typing (#8) — 15-20 files, internal only
- StackArgs per-operation validation (#4) — large scope

---

## Codebase Reference

| What                      | Where                                              |
|---------------------------|----------------------------------------------------|
| Russell review            | `notes/2026-03-02-russell-review.md`               |
| Snapshot gap audit        | `notes/2026-03-02-snapshot-gap-audit.md`           |
| StackArgsLoader           | `src/Iidy/Cfn/StackArgsLoader.hs`                 |
| RequestBuilder            | `src/Iidy/Cfn/RequestBuilder.hs`                   |
| Params                    | `src/Iidy/Ssm/Params.hs`                          |
| TemplateApproval          | `src/Iidy/Cfn/Operations/TemplateApproval.hs`     |
| Resolver                  | `src/Iidy/Yaml/Resolution/Resolver.hs`            |
| CLI                       | `src/Iidy/Cli.hs`                                 |

---

## Progress

_To be filled in by executing agent._

## Handoff Notes

_To be filled in by executing agent._
