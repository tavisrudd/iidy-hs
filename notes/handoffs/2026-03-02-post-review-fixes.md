# Post-Review Fixes — All Open Findings

**Date**: 2026-03-02
**Prior session**: Session 46 — all handoff chunks complete, 7 reviews done + annotated
**Strategy**: Work through open findings from all reviews, snapshot audit, and Russell analysis. Sections are independent — sub-agents can work in parallel worktrees.

---

## Context

Session 46 produced 7 architecture reviews, a Russell API review (20 findings), and a
snapshot gap audit. Many findings overlap across reviews. This handoff consolidates ALL
open work into one document, grouped by theme.

**Current state**: 1150 tests, zero warnings.

**Reviews**: hickey, kmett, krishnamurthi, minsky, muratori, ousterhout, russell
**Audit**: `notes/2026-03-02-snapshot-gap-audit.md`

---

## Section 1: Silent Drops (Russell -7/-8)

The systemic pattern: IO boundaries accept bad input and silently do the wrong thing.
These are the highest-priority fixes — each one is a user-facing bug.

**Sub-agent strategy**: Chunks A-C can share a worktree (all touch StackArgsLoader).
D-F are independent and can each be separate worktrees.

### 1A: `param get --format json` silently ignored (Russell #19, rating -8)

The `--format json` flag is parsed into a `ParamFormat` ADT but the command ignores it
and always outputs raw text.

1. Read `src/Iidy/Ssm/Params.hs` — find the `param get` implementation
2. Read `src/Iidy/Cli.hs` — find ParamFormat and how --format is parsed
3. Check Rust: does `iidy param get --format json` produce structured output?
4. Decision: implement JSON output OR reject at parse time with a clear error
5. Add tests, run `cabal test`

**Files**: 2-3 (`Params.hs`, `Cli.hs`, test file)
**Risk**: Low. Currently broken anyway.

### 1B: `--context` flag accepted but never applied (Russell #20, rating -6)

The `--context` flag for template-approval is parsed and stored but never used.

1. Read `src/Iidy/Cfn/Operations/TemplateApproval.hs` — find where diff is generated
2. Check Rust: does `--context` work there?
3. Either implement context-line trimming or remove the flag from the parser
4. Add tests, run `cabal test`

**Files**: 1-2 (`TemplateApproval.hs`, possibly `Cli.hs`)
**Risk**: Low.

### 1C: `getStrList` silently drops non-string elements (Russell #3, rating -7)

`getStrList` in StackArgsLoader filters out non-string elements instead of erroring.

1. Read `src/Iidy/Cfn/StackArgsLoader.hs` — find `getStrList`
2. Change to error on non-string elements with a clear message
3. Add test for mixed-type list rejection
4. Run `cabal test`

**Files**: 1-2 (`StackArgsLoader.hs`, test file)
**Risk**: Low.

### 1D: Unknown YAML keys in stack-args silently ignored (Russell #10, rating -7)

Typos in stack-args.yaml keys are silently ignored.

1. Read `src/Iidy/Cfn/StackArgsLoader.hs` — understand which keys are valid
2. Check Rust behavior — does it warn/error on unknown keys?
3. After parsing known keys, check for remaining unknown keys
4. Error with a message listing the unknown keys and suggesting corrections
5. Add tests, run `cabal test`

**Files**: 1-2 (`StackArgsLoader.hs`, test file)
**Risk**: Medium. Could break configs with non-standard keys. Check Rust first.

### 1E: `getStackName` falls back to "unnamed-stack" (Russell #2, rating -7)

When `saStackName` is `Nothing`, `getStackName` returns `"unnamed-stack"`.

1. Read `src/Iidy/Cfn/RequestBuilder.hs` — find `getStackName`
2. Change to return `Either Text Text` or error early
3. Fix callers to handle the missing-name case explicitly
4. Add test, run `cabal test`

**Files**: 2-3 (`RequestBuilder.hs`, callers, test file)
**Risk**: Low. "unnamed-stack" was never a correct fallback.

### 1F: Dot-path query returns ONull on miss (Russell #11, rating -7)

`applyDotQueryValidated` returns `ONull` when a path component doesn't exist.

1. Read the resolver — find `applyDotQueryValidated`
2. Check Rust behavior — does it also return null on miss?
3. If Rust errors: fix to match. If Rust returns null: document as intentional.
4. Add tests either way.

**Files**: 1-2 (resolver, test file)
**Risk**: Medium. Changing null-on-miss to error could break valid templates.

### 1G: GlobalConfig silently swallows all errors (Russell #7, rating -7)

GlobalConfig catches `SomeException` (including async exceptions) and converts to
misleading error messages.

1. Read `src/Iidy/Cfn/GlobalConfig.hs` — find exception handling
2. Narrow `SomeException` to `IOException` or `Amazonka.Error`
3. Let async exceptions propagate
4. Add test, run `cabal test`

**Files**: 1-2 (`GlobalConfig.hs`, test file)
**Risk**: Medium. Changing exception handling could surface new errors.

---

## Section 2: Snapshot Fixes

From `notes/2026-03-02-snapshot-gap-audit.md`. These are correctness bugs.

**Sub-agent strategy**: 2A is independent. 2B is trivial. 2C is research + implementation.

### 2A: CFN validator rejects nested intrinsics (2 render failures)

`advanced-cloudformation.yaml` and `string-formatting-demo.yaml` fail because the CFN
validator rejects `!Select [0, !GetAZs ""]` — it sees `!GetAZs` as an "object" at the
AST level rather than recognizing it as a CFN intrinsic that produces an array at deploy time.

1. Read `src/Iidy/Yaml/Cfn/Validator.hs` (or wherever CFN validation lives)
2. Find the logic that checks `!Select` argument types
3. Fix to recognize nested CFN intrinsics as valid (they resolve at deploy time)
4. Both fixtures should now pass `scripts/snapshot-compare.sh`
5. Add tests, run `cabal test`

**Files**: 1-2 (validator, test file)
**Risk**: Low. Making the validator less strict for nested intrinsics.

### 2B: "sequence" vs "array" wording (1 error failure)

`cloudformation-empty-arrays` error says "sequence" where Rust says "array".

1. Find the error message that says "sequence" for CFN array contexts
2. Change to "array" to match Rust
3. Update the error content test if needed
4. Run `scripts/error-snapshot-compare.sh`

**Files**: 1 (error message source)
**Risk**: Zero. Cosmetic wording fix.

### 2C: Port 4 missing yaml-iidy-syntax fixtures from Rust

Rust has 4 fixtures we don't: `defs-dynamic-scoping`, `defs-handlebars-cross-reference`,
`defs-mixed-references`, `include-equivalence2`.

1. Read each Rust fixture in `~/src/iidy/tests/` (find exact paths)
2. Port to `test-fixtures/example-templates/`
3. Run through our preprocessor, compare output to Rust snapshots
4. Add expected-output files and wire into cabal test
5. Fix any divergences found

**Files**: 4+ fixture files + expected outputs
**Risk**: Low. May surface divergences.

### 2D: Add expected-output for `config` and `import-test` fixtures

These 2 fixtures pass snapshot comparison but have no `cabal test` expected-output files.

1. Run each fixture, capture output
2. Add expected-output files
3. Wire into FixtureTest
4. Run `cabal test`

**Files**: 2 expected-output files
**Risk**: Zero.

---

## Section 3: Remaining Russell Findings (Medium Priority)

These are real issues but require more care or have wider blast radius.

### 3A: `try @SomeException` at 15+ AWS boundaries (Russell #17, rating -4)

Same anti-pattern as GlobalConfig but across 15+ call sites. Catches async exceptions
and converts them to misleading error messages.

1. Grep for `try @SomeException` and `catch.*SomeException` across the codebase
2. For each site, determine the appropriate narrow exception type
3. Replace progressively — start with the most dangerous sites
4. Run `cabal test` after each change

**Files**: 10+ files
**Risk**: Medium-High. Changing exception handling could surface new failure modes.

### 3B: Error classification via string matching (Russell #16, rating -2)

`classifyMessage'` in Conversion.hs matches error strings from other modules. Fragile
cross-module coupling.

1. Read `src/Iidy/Yaml/Errors/Conversion.hs` — `classifyMessage'`
2. Consider: could the resolver/parser return structured error kinds directly?
3. If yes, design the approach. If not, at minimum add tests covering the coupling.

**Files**: 2-3 (Conversion.hs, error source modules)
**Risk**: Medium. Changes error classification for all 51 error fixtures.

### 3C: requestConfirmation Bool hides exit-code semantics (Russell #18, rating +3)

`Iidy.Confirm` returns `Bool` but decline means exit 130 (cancellation) for most commands
and exit 1 (deliberate rejection) for `template-approval review`.

1. Read `src/Iidy/Confirm.hs` — current API
2. Consider: return `ConfirmResult = Confirmed | Cancelled | Rejected`?
3. If changing, update all callers

**Files**: 2-4 (`Confirm.hs`, callers)
**Risk**: Low.

---

## Section 4: Structural Improvements (Lower Priority)

These are OPEN findings from multiple reviews that require larger refactoring. Only
attempt these if sections 1-3 are complete. Each is a session unto itself.

### 4A: Terminal statuses as stringly typed
**Reviews**: Hickey #7, Minsky #2, Kmett #8, Russell #8
Convert `Text` stack statuses to a proper ADT. Touches 15-20 files.

### 4B: CfnContext separation
**Reviews**: Hickey #1, Minsky #4, Ousterhout #1a/#2a
Split CfnContext into read-only and mutable parts. 16+ files.

### 4C: StackArgsLoader extraction / per-operation validation
**Reviews**: Hickey #6, Ousterhout #5, Russell #4, Minsky #1
Per-operation config types, unknown-key validation, aeson Value → direct parse.

### 4D: Import loader abstraction
**Reviews**: Kmett #7
10 import loaders all reimplement fetch/parse/wrap independently.

### 4E: OValue/Value unification
**Reviews**: Hickey #4, Kmett #5
Three-representation pipeline (YamlAst → OValue → Value) with manual conversions.

### 4F: Benchmarks
**Reviews**: Muratori #6
No performance measurement exists. Startup time and preprocessing latency unmeasured.

---

## Codebase Reference

| What                      | Where                                              |
|---------------------------|----------------------------------------------------|
| Russell review            | `notes/2026-03-02-russell-review.md`               |
| Hickey review             | `notes/2026-03-02-hickey-review.md`                |
| Ousterhout review         | `notes/2026-03-02-ousterhout-review.md`            |
| Minsky review             | `notes/2026-03-02-minsky-review.md`                |
| Krishnamurthi review      | `notes/2026-03-02-krishnamurthi-review.md`         |
| Kmett review              | `notes/2026-03-02-kmett-review.md`                 |
| Muratori review           | `notes/2026-03-02-muratori-review.md`              |
| Snapshot gap audit        | `notes/2026-03-02-snapshot-gap-audit.md`           |
| StackArgsLoader           | `src/Iidy/Cfn/StackArgsLoader.hs`                 |
| RequestBuilder            | `src/Iidy/Cfn/RequestBuilder.hs`                   |
| GlobalConfig              | `src/Iidy/Cfn/GlobalConfig.hs`                     |
| Params                    | `src/Iidy/Ssm/Params.hs`                          |
| TemplateApproval          | `src/Iidy/Cfn/Operations/TemplateApproval.hs`     |
| Resolver                  | `src/Iidy/Yaml/Resolution/Resolver.hs`            |
| Errors/Conversion         | `src/Iidy/Yaml/Errors/Conversion.hs`              |
| Confirm                   | `src/Iidy/Confirm.hs`                             |
| CLI                       | `src/Iidy/Cli.hs`                                 |

---

## Progress

| Item | Status    | Commit  | Notes                                                |
|------|-----------|---------|------------------------------------------------------|
| 1A   | DONE      | 46cbde7 | Full port: ParamOutput/HistoryOutput types, ListTagsForResource, json/yaml/simple format, 31 new tests. |
| 1B   | DONE      | e3453c4 | LCS diff algorithm + contextLines wiring. 15 new tests. |
| 1C   | DONE      | 837536d | getStrListValidated replaces silent-drop getStrList. 6 new tests. |
| 1D   | PENDING   | —       | Needs user confirmation (behavior change).           |
| 1E   | PENDING   | —       | Needs user confirmation (behavior change).           |
| 1F   | PENDING   | —       | Needs user confirmation (behavior change).           |
| 1G   | DONE      | 33eb121 | Catch Amazonka.Error not SomeException. Silent on empty path, warns on other AWS errors. |
| 2A   | DONE      | 836e3f5 | isCfnIntrinsic for !Select/!Join/!Split. 2 new fixture expected-outputs. |
| 2B   | DONE      | 63152be | cfnTypeName returns "array" for OArray in CFN validator context. |
| 2C   | DONE      | 12b178f | Reverse-engineered 4 fixtures from Rust snapshots (input files missing from Rust too). All pass cabal test + snapshot-compare. |
| 2D   | DONE      | 65d54de | Expected-output files for config + import-test.      |
| 3A   | PENDING   | —       | try @SomeException at 15+ AWS boundaries.            |
| 3B   | PENDING   | —       | Error classification via string matching.            |
| 3C   | DONE      | 6ca9fb3 | ConfirmResult ADT (Confirmed/Declined), Text not String. 6 call sites updated. |
| 4A-F | PENDING   | —       | Structural improvements — larger refactoring.        |

**Tests**: 1091 → 1150 (+59)

## Handoff Notes

### Session 47 (2026-03-02)
- Completed 5 items from sections 1 and 2 (1B, 1C, 2A, 2B, 2D)
- 1G in-flight via sub-agent
- User guidance on behavior-changing items:
  - **1D/1E/1F**: Confirm with user before implementing (changes non-broken behavior)
  - **1G**: User approved — silent on missing SSM path, warnings for other errors, candidate for removal
- **1A** completed — full port with 6 new types, ListTagsForResource, custom YAML formatter, 31 new tests.
- **2C** (port 4 missing fixtures) is straightforward research + fixture work
- **3A** (SomeException at 15+ sites) is medium-high risk, should be done progressively

### Session 2026-03-02--3 (`91ca49f6-a009-46e0-a321-aed048a27002`)
**Completed**:
- Fixed -Wx-partial warning: `List.head` → `error` in unreachable branch (e8ceaaa)
- Ported 4 missing yaml-iidy-syntax fixtures from Rust snapshots (12b178f) — 2C
- Updated CLAUDE.md: session numbering format, sub-agent git rules (42881fb)
- Replaced requestConfirmation Bool → ConfirmResult ADT (6ca9fb3) — 3C
- Memory audit: MEMORY.md trimmed 78→14 lines, stale files deleted
- Created t-later skill, updated t-handoff/t-done with session numbering
- SessionStart hook now assigns per-project YYYY-MM-DD--N session numbers
**Files modified**: `src/Iidy/Confirm.hs`, `src/Iidy/Cfn/Operations/{DeleteStack,Changeset,UpdateStack,CreateOrUpdate,TemplateApproval}.hs`, `src/Iidy/Params/Review.hs`, `CLAUDE.md`, 8 fixture files
**Notes for next session**:
- 1D/1E/1F still need user sign-off before implementing (behavior changes)
- 3A (SomeException at 15+ sites) is the next substantive code item — do progressively
- 3B (error classification string matching) needs design thought before code
- 4A-F are larger structural refactors — only if sections 1-3 fully done
- `$CLAUDE_SESSION_NUM` and `$CLAUDE_SESSION_ID` env vars now available via SessionStart hook
