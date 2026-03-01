# Review #1 Remaining Fixes -- Bug-Fix Batch

**Date**: 2026-02-28
**Session**: `bc778d26-2dea-4022-a23f-fdad1f0fd614`
**References**:
- Review: `notes/2026-02-28-review-1-yaml-resolver-errors.md`
- Fixes so far: `notes/2026-02-28-review-1-fixes.md`

## Context

An Opus code review of the YAML resolver + error subsystem found ~30 issues.
Session 1 fixed the critical/major ones (partial functions, deduplication,
infinite loop, safe indexing) and added 92 tests (resolver unit tests,
classifyMessage unit tests, ErrorId round-trip, expand error fixtures).

This handoff covers the remaining actionable items. Some review findings
were false alarms (documented in the fixes doc). What remains is cleanup,
dead code removal, and minor refactoring — no correctness bugs.

**Current state**: 561 tests, zero warnings, clean build.

## Issues to Fix

### A. Dead code removal: `resolveResourcesMapping` + `tcInResourcesSection` (Medium)

The investigation confirmed `tcInResourcesSection` is never set to `True`
anywhere. `resolveResourcesMapping` is unreachable dead code. The active
path is `resolveMappingWithExpansion`.

**Files**:
- `src/Iidy/Yaml/Resolution/Resolver.hs` — remove `resolveResourcesMapping`
  (lines 170-196), remove guard at line 102, remove `tcInResourcesSection`
  references (lines 172, 223)
- `src/Iidy/Yaml/Resolution/Context.hs` — remove `tcInResourcesSection`
  field (line 34) and its initialization (line 42)

**Fix**: Delete the dead code. The first guard in `resolveMapping` (line 102)
can be removed entirely. The second guard (`hasResourcesKey`) becomes the
only custom-resource-expansion path.

**Verify**: `cabal build` should succeed (any remaining references will be
compile errors). All 561 tests must still pass.

### B. Dead field removal: `tpiCaretColumn` (Low)

`tpiCaretColumn` is defined in `Enhanced.hs` line 56, always set to `0`
in Conversion.hs (10 sites), and never read anywhere.

**Files**:
- `src/Iidy/Yaml/Errors/Enhanced.hs` — remove `tpiCaretColumn` from
  `TagParsingInfo` record
- `src/Iidy/Yaml/Errors/Conversion.hs` — remove all 10 `, tpiCaretColumn = 0`
  lines (109, 122, 135, 201, 214, 232, 250, 263, 276, 396)
- `test/Test/ErrorClassificationTest.hs` — remove any `tpiCaretColumn`
  assertions if the sub-agent included them

**Verify**: compile + test.

### C. `T.length "constant"` → `T.stripPrefix` cleanup (Low)

12 sites in Conversion.hs use `T.drop (T.length "some prefix") msg`
which computes `T.length` of a literal at runtime. Replace with
`T.stripPrefix` where the prefix was already checked by a guard.

**Pattern**:
```haskell
-- Before:
| "Variable not found: " `T.isPrefixOf` msg =
    let rest = T.drop (T.length "Variable not found: ") msg

-- After (use fromMaybe as safety net since guard already matched):
| Just rest <- T.stripPrefix "Variable not found: " msg =
-- OR keep the guard and use stripPrefix in the body:
    let rest = fromMaybe msg (T.stripPrefix "Variable not found: " msg)
```

**Caution**: The guards in `classifyMessage` use `T.isPrefixOf` / `T.isSuffixOf`
with `|` syntax. Switching to `Just rest <- T.stripPrefix` in a guard requires
`PatternGuards` (enabled by default in GHC2021). This is safe but test each change.

**Sites** (Conversion.hs): lines 141, 145, 150, 173, 177, 192, 284, 285,
327, 343, 470, 720.

### D. `PC-C1`: Thread `allLines` to avoid repeated `T.lines` (Low)

Several functions in Conversion.hs call `T.lines source` independently.
For a single error, `T.lines` may be called 3-5 times on the same text.

**Fix**: Change `adjustLocationForTag` to compute `allLines` once and
pass it to helpers. This requires changing the signatures of:
- `adjustForTypeMismatch` — already takes `[Text]` ✓
- `findVariableColumn` — already takes `[Text]` ✓
- `findTagOnSourceLine` — currently takes `Text` source, change to `[Text]`
- `findTagExampleForUnexpectedField` — currently takes `Text` source, change to `[Text]`

Also `formatPreprocessErrorEnhanced` / `formatParseErrorEnhanced` could
compute `allLines` once and pass through, but this is lower priority since
errors are only formatted once per failure.

### E. Missing CFN tag validation (Low)

`validateCfnTag` in Resolver.hs covers 10 tags but silently passes for
`!Sub`, `!GetAtt`, `!Split`, `!Cidr`, `!Length`, `!ToJsonString`,
`!Transform`, `!ForEach`, `!And`, `!Or`.

**Approach**: Check Rust's `validate_cfn_tag` at
`~/src/iidy/src/yaml/resolution/resolver.rs` to see which tags Rust
validates and what the rules are. Add matching validation. This needs
an Explore sub-agent to read the Rust source first.

### F. Conversion.hs split (Deferred)

At 884 LOC, Conversion.hs exceeds the 300-500 LOC guideline. Natural
split points:
1. Error classification (`classifyMessage` + helpers) → `Classification.hs`
2. Source position adjustment (`adjustLocationForTag` + helpers) → `PositionAdjust.hs`
3. String search utilities → `SourceSearch.hs`
4. Tag examples and CFN help text → `HelpText.hs`

This is a larger refactor that should be done in its own session if desired.
Not blocking anything.

## Codebase Reference

| What                            | Where                                              |
|---------------------------------|----------------------------------------------------|
| Resolver (main fixes target)    | `src/Iidy/Yaml/Resolution/Resolver.hs` (798 lines) |
| Tag context definition          | `src/Iidy/Yaml/Resolution/Context.hs` (lines 25-45) |
| Error conversion (main target)  | `src/Iidy/Yaml/Errors/Conversion.hs` (884 lines)   |
| Enhanced error types            | `src/Iidy/Yaml/Errors/Enhanced.hs`                  |
| Error display                   | `src/Iidy/Yaml/Errors/Display.hs` (246 lines)       |
| Resolver unit tests             | `test/Test/ResolverTest.hs` (49 tests)               |
| Error classification tests      | `test/Test/ErrorClassificationTest.hs` (35 tests)    |
| ErrorId tests                   | `test/Test/ErrorIdTest.hs` (6 tests)                 |
| Fixes tracking doc              | `notes/2026-02-28-review-1-fixes.md`                 |
| Rust resolver (read-only ref)   | `~/src/iidy/src/yaml/resolution/resolver.rs`         |

## Build/Test Commands

Per CLAUDE.md. Use `~/.claude/bin/run-quiet` for noisy output.

## Delegation Strategy

| Issue | Delegate? | Agent     | Why                                                   |
|-------|-----------|-----------|-------------------------------------------------------|
| A     | Yes       | Sonnet    | Mechanical deletion with clear scope                   |
| B     | Yes       | Sonnet    | Mechanical deletion, even simpler than A               |
| C     | Yes       | Sonnet    | Pattern-match replacement, 12 sites, no design choices |
| D     | Yes       | Sonnet    | Signature changes, straightforward threading           |
| E     | No        | Opus main | Needs Rust source research + validation design         |
| F     | Deferred  | —         | Large refactor, separate session if desired             |

**A+B can run in parallel** (no file overlap except a build step).
**C+D are sequential** (both touch Conversion.hs).
**E is independent** (touches Resolver.hs only).

## Workflow Instructions

1. Read this file and `notes/2026-02-28-review-1-fixes.md`
2. Check Progress below for what's next
3. Launch A+B as parallel Sonnet sub-agents
4. After A+B pass, launch C as Sonnet sub-agent, then D
5. For E, use an Explore agent to read Rust validation code first, then implement
6. After each issue, build + test (`cabal clean && cabal build && cabal test`)
7. **Update `notes/2026-02-28-review-1-fixes.md`** — move completed items from
   "Remaining Unfixed Issues" table to the "Code Fixes Applied" tables above
8. Update Progress below and add Handoff Notes
9. **When all done**: append a `## Session Summary` section at the bottom of
   `notes/2026-02-28-review-1-fixes.md` with final test count, what was fixed,
   what remains (if anything), and the revised grade assessment

## Progress

- [x] A: Remove dead code `resolveResourcesMapping` + `tcInResourcesSection`
- [x] B: Remove dead field `tpiCaretColumn`
- [x] C: `T.length "constant"` → `T.stripPrefix` (12 sites)
- [x] D: Thread `allLines` to avoid repeated `T.lines`
- [x] E: Add missing CFN tag validation (research Rust first)
- [ ] F: (Deferred) Split Conversion.hs into smaller modules
- [x] Final: clean build + all tests pass + update fixes doc

## Handoff Notes

### Session 1 (2026-02-28)

**Session**: `bc778d26-2dea-4022-a23f-fdad1f0fd614`
**Completed**:
- All critical/major code fixes (partial functions, dedup, expandBrackets depth limit)
- 92 new tests: ResolverTest (49), ErrorClassificationTest (35), ErrorIdTest (6), expand error fixtures (2)
- R2/R3 investigation → both false alarms (documented)
- Exported `classifyMessage` from Conversion.hs for testing

**Files created**:
- `test/Test/ResolverTest.hs`
- `test/Test/ErrorClassificationTest.hs`
- `test/Test/ErrorIdTest.hs`
- `test-fixtures/example-templates/errors/expand-missing-template.yaml`
- `test-fixtures/example-templates/errors/expand-parse-error.yaml`
- `notes/2026-02-28-review-1-fixes.md`

**Files modified**:
- `src/Iidy/Yaml/Resolution/Resolver.hs` — 7 fixes
- `src/Iidy/Yaml/Errors/Conversion.hs` — 5 fixes + export added
- `src/Iidy/Yaml/Errors/Display.hs` — 2 fixes
- `test/Main.hs` — 3 test groups added
- `iidy-hs.cabal` — 3 test modules added

### Session 2 (2026-02-28)

**Completed**: All items A-E. Updated fixes doc with session summary.
**Commit**: `01a7c4c` — Review cleanup: dead code, T.stripPrefix, allLines threading, CFN validation
**Notable**: CFN tag validation required adding single-element array unpacking to `resolveCfnTag` (matching Rust behavior). Also added `!Sub`/`!GetAtt`/`!Split` deep validation + null catch-all for all remaining tags.
**Remaining**: NI-C1 (structured error types — future session), CS-C1 (module split — deferred), PC-R1 (by design).

**Notes for next session**:
- Conversion.hs was modified by both main agent and TG-C1 sub-agent (export added).
  Current state has `classifyMessage` in the export list — this is intentional.
- The `safeLine` helper added to Conversion.hs (line ~677) is also used internally.
  If splitting the module (issue F), it should go with the position-adjustment code.
- Issue A: after deleting `resolveResourcesMapping`, the `deduplicateResources`
  top-level function is still needed by `resolveMappingWithExpansion` — don't delete it.

### Session 3 (2026-02-28, night)

**Completed**: All remaining actionable items + bonus work beyond original scope.
**Commits**:
- `01a7c4c` — Review cleanup: dead code, T.stripPrefix, allLines threading, CFN validation (A-E)
- `7da92f6` — Doc updates
- `891352e` — NI-C1: Structured resolve errors (ResolveErrorKind sum type)
- `54db3bd` — Doc update for NI-C1
- `92abaa5` — Review 1b fixes: CFN error message bug, dead code removal
- `68e7e65` — 125 new tests: 13 resolver tag groups + CFN validation

**Beyond original scope**:
- NI-C1: Replaced string-based error classification with `ResolveErrorKind` (10 variants) + smart constructors
- Fixed ImportError `show` bug (constructor name wrapping)
- Ran independent review 1b (Opus, no prior review context) — found and fixed BUG-1 (wrong type in CFN error messages)
- Removed dead code: `VariableSource` type, `withInputUri` function
- Added 125 tests covering all 22 resolver tags + all CFN validation rules
- Review 1c grade assessment written

**Final state**: 686 tests, zero warnings, clean build.
**Only deferred item**: F (Conversion.hs module split) — not blocking anything.
