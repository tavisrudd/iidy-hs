# Refactor constructCommandMetadata to not require StackArgs

**Date**: 2026-03-02
**Purpose**: Eliminate the pattern of passing dummy `emptyStackArgs` to functions that don't need a full StackArgs.

---

## Context

`constructCommandMetadata` takes a `StackArgs` parameter, but two callers (`CmdExecChangeset` and `CmdDeleteStack` in `app/Main.hs`) don't load a stack-args file — they pass `emptyStackArgs` as a dummy value. The stack name and other config come from CLI args directly.

This is a code smell: the function asks for more than it needs, and callers lie by fabricating a struct they don't have. Now that `saStackName` is `!Text` (non-optional, validated at parse time), `emptyStackArgs` uses `""` as a placeholder — which is honest but ugly.

## Scope

- **In scope**: Refactor `constructCommandMetadata` to take only the fields it actually reads from StackArgs (likely region, profile, tags, etc.)
- **In scope**: Audit other functions that take `StackArgs` but only use a subset of fields
- **Out of scope**: Full per-operation config types (that's 4C in the post-review handoff)

## Work Items

### A: Audit what constructCommandMetadata reads from StackArgs

Read `src/Iidy/Cfn/CommandMetadata.hs` (or wherever it lives). List exactly which StackArgs fields it accesses. This determines the minimal parameter set.

### B: Extract a smaller type or use direct parameters

Either:
- Pass individual fields: `constructCommandMetadata ctx aws region profile tags env template`
- Or define a lightweight record for the metadata context (if >3 fields)

### C: Remove emptyStackArgs usage from Main.hs

The two `emptyStackArgs` sites in Main.hs should pass the real values directly.

### D: Consider emptyStackArgs itself

If no production code uses `emptyStackArgs` after this refactor (only tests), document that. Tests may still want it for convenience.

## Codebase Reference

| What                         | Where                            |
|------------------------------|----------------------------------|
| constructCommandMetadata     | grep for definition              |
| emptyStackArgs callers       | `app/Main.hs:172,217`           |
| emptyStackArgs definition    | `src/Iidy/Cfn/Types.hs:110-131` |
| Post-review 4C (larger work) | `notes/handoffs/2026-03-02-post-review-fixes.md` |

## Delegation

- **Can delegate to sub-agent?** Yes
- **Model**: Sonnet
- **Notes**: Straightforward once the audit in step A is done
