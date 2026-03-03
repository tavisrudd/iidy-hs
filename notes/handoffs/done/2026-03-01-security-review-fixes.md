# Security Review Fixes (Codex Findings) -- Bug Fix Batch

**Status**: DONE
**Date**: 2026-03-01
**Session**: `9b77427d-2cd4-4c4b-a7a0-d2726e72261d`
**References**: Codex security review comments

## Context

Codex review flagged 3 security concerns:

1. `parseImportType` (the security classification function) was implemented
   but never called by the runtime dispatcher — the trust model (remote base
   templates cannot load local-only imports) was not enforced
2. Regex evaluation on user/schema patterns via `=~` could create ReDoS risk
3. HTTP import loader had no timeout or response size cap

## Issues Fixed

### A. Import trust gate: wire parseImportType into dispatcher

**Problem**: `Dispatch.hs` routed by string prefix (`T.isPrefixOf`) directly,
bypassing `parseImportType` which enforces the security rule: imports from
remote base locations (S3, HTTP) cannot load local-only types (file, env, git,
filehash). The Rust dispatcher uses `ImportType::from_location()` as a gate.

**Fix**: Rewrote `mkFullDispatcher` to call `parseImportType` first (returning
errors immediately), then dispatch via a `case` on the resulting `ImportType`.
Removed all `T.isPrefixOf` guards — the type classification and security check
now happen in one place (`Types.hs`).

### B. Regex pattern length cap

**Problem**: `validatePattern` (JSON Schema) and `validateAllowedPattern`
(CFN params) used `=~` with patterns from template definitions. While
`regex-tdfa` is NFA-based (immune to classic catastrophic backtracking),
extremely long patterns can still cause high compilation cost.

**Fix**: Added `maxRegexPatternLength = 1024` constant. Both validators
reject patterns exceeding this length with a clear error. Note: these
patterns come from template authors (not untrusted external input), so
this is defense-in-depth.

### C. HTTP import timeout and size cap

**Problem**: `fetchHttp` used `httpBS` with no timeout or size limit. A
slow or malicious server could hang the process or exhaust memory.

**Fix**: Added `httpTimeoutSeconds = 30` and `httpMaxResponseBytes = 10 MB`
constants. `fetchHttp` now sets `responseTimeoutMicro` on the request, and
`loadHttpImport` rejects responses exceeding the size cap. Added
`http-client` dependency for `responseTimeoutMicro`.

**Rust comparison**: Rust's HTTP loader (`reqwest::Client::new()`) also has
no explicit timeout or size cap, so this is a divergence in Haskell's favor.

### D. Move Iidy.Cfn.Constants → Iidy.Constants

Moved constants to project-wide `Iidy.Constants` module. All constants
(CFN polling, HTTP limits, regex limits) now in one place. Removed
dead-code duplicates (`*SuccessStates` were already in `Context.hs`).

## Files Modified

| File                                       | Changes                                        |
|--------------------------------------------|-------------------------------------------------|
| `iidy-hs.cabal`                            | +`http-client` dep, rename constants module     |
| `src/Iidy/Constants.hs`                    | New: project-wide constants                     |
| `src/Iidy/Cfn/Constants.hs`               | Deleted (moved to Iidy.Constants)               |
| `src/Iidy/Yaml/Imports/Loaders/Dispatch.hs`| Rewritten: parseImportType gate + case dispatch |
| `src/Iidy/Yaml/Imports/Loaders/Http.hs`   | Timeout + size cap                              |
| `src/Iidy/Yaml/CustomResources/JsonSchema.hs` | Pattern length cap                          |
| `src/Iidy/Yaml/CustomResources/Params.hs` | Pattern length cap                              |
| `src/Iidy/Cfn/Operations/{Delete,Watch,Changeset}Stack.hs` | Import path update         |

## Handoff Notes

### Completion (2026-03-01)

**Session**: `9b77427d-2cd4-4c4b-a7a0-d2726e72261d`
**Completed**: All 3 Codex findings + constants consolidation.
**Deviations**: Added Iidy.Constants module move (not in original scope
but needed for central constant placement). Rust HTTP loader also lacks
timeout/size cap, so this is a proactive improvement.
