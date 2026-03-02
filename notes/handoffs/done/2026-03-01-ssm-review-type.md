# SSM Review: Preserve Parameter Type -- Bug Fix

**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`
**References**: Gemini review R1-2; Rust `~/src/iidy/src/params/review.rs:36-39,66-71`

## Context

`applyPendingChange` in `Iidy.Params.Review` hardcodes `ParameterType_SecureString` when
writing the approved value. The Rust version reads the pending parameter's actual type and
preserves it (defaulting to SecureString only if the type field is None).

This means approving a `String` or `StringList` parameter silently converts it to `SecureString`.

## Issue

**File**: `src/Iidy/Params/Review.hs:90-96`

**Current** (line 95):
```haskell
let putReq = (PP.newPutParameter path pendingValue)
              { PP.overwrite = Just True
              , PP.type' = Just SSMPT.ParameterType_SecureString  -- HARDCODED
              }
```

**Rust behavior** (`review.rs:36-39`): Reads `pending_param.type()`, falls back to "SecureString".

**Fix**: Thread the pending parameter's type through to `applyPendingChange`. The pending
parameter is already fetched via `fetchParam` — change it to return the full `Parameter`
(or at least the type) instead of just the value text.

### Concrete approach

1. In `paramReview`, after fetching the pending parameter, extract its type
2. Pass the type to `applyPendingChange`
3. Use the extracted type in the `PutParameter` request, defaulting to SecureString if None

The pending parameter's type is available on the `Parameter` response object via
`SSMP.parameter_type'` lens. After the dedup fix (R1-3), `fetchParam` will come from
`Client.hs` — so we need a variant that returns the type too, or a separate
`fetchParamFull` that returns the raw `Parameter`.

## Codebase Reference

| What                     | Where                                        |
|--------------------------|----------------------------------------------|
| Review module            | `src/Iidy/Params/Review.hs` (107 LOC)        |
| applyPendingChange       | `src/Iidy/Params/Review.hs:90-106`           |
| paramReview entry point  | `src/Iidy/Params/Review.hs:40-74`            |
| SSM Parameter type lens  | `Amazonka.SSM.Types.Parameter.parameter_type'` |
| Rust reference           | `~/src/iidy/src/params/review.rs:36-39`       |

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — isolated change in one module
- **Isolation**: Worktree (parallel with pagination fix)
- **Note**: If R1-3 (dedup) lands first, Review.hs will import fetchParam from Client.hs.
  This fix should work with either pre- or post-dedup state — just add a `fetchParamWithType`
  or similar to whichever module owns the fetch logic.

## Progress

- [ ] Extract pending parameter type from SSM response
- [ ] Pass type to applyPendingChange
- [ ] Default to SecureString only when type is Nothing
- [ ] Build clean, all tests pass

## Handoff Notes

(to be filled by implementing session)
