# Fix Template Approval Error Propagation -- Bug Fix

**Date**: 2026-03-01
**Session**: `9b77427d-2cd4-4c4b-a7a0-d2726e72261d`
**References**: Codex review, Rust `src/cfn/template_approval_review.rs:209-246`

## Context

The template approval finalize path in `TemplateApproval.hs` silently
discards S3 upload/delete failures. The three S3 operations on lines
175-177 use `_ <-` to discard `Either Text ()` results, always reporting
success (exit 0) and `arCleanupCompleted = True` regardless of whether
the operations actually succeeded.

Rust uses `?` on all three operations, propagating errors as exit code 1.

## Issues to Fix

### A. S3 upload/delete failures silently discarded (lines 175-177)

```haskell
-- Current (broken):
_ <- uploadToS3 (cfnEnv ctx) bucket approvedKey pending
_ <- uploadToS3 (cfnEnv ctx) bucket latestKey pending
_ <- deleteFromS3 (cfnEnv ctx) bucket pendingKey
```

**Fix**: Check each `Either` result. On `Left`, return the error:

```haskell
uploadApproved <- uploadToS3 (cfnEnv ctx) bucket approvedKey pending
case uploadApproved of
  Left err -> pure (Left ("Failed to upload approved template: " <> err))
  Right () -> do
    uploadLatest <- uploadToS3 (cfnEnv ctx) bucket latestKey pending
    case uploadLatest of
      Left err -> pure (Left ("Failed to upload latest template: " <> err))
      Right () -> do
        deleteResult <- deleteFromS3 (cfnEnv ctx) bucket pendingKey
        case deleteResult of
          Left err -> pure (Left ("Failed to delete pending template: " <> err))
          Right () -> do
            emit $ OdApprovalResult ApprovalResult { ... arCleanupCompleted = True }
            pure (Right 0)
```

This matches the request path (lines 83-85) which already handles upload errors correctly.

### B. Pending template download failure swallowed (line 148)

```haskell
-- Current (broken):
let pending = either (const "") id pendingTemplate
```

If downloading the pending template fails, the error is silently turned
into an empty string. This is wrong — we just verified the pending key
exists (line 126). A download failure is a real error.

Note: the `latest` download failure on line 149 IS correctly lenient —
the latest template may not exist yet. Only the pending download needs
fixing.

**Fix**:
```haskell
case pendingTemplate of
  Left err -> pure (Left ("Failed to download pending template: " <> err))
  Right pending -> do
    let latest = either (const "") id latestTemplate
    -- ... continue with pending and latest
```

## Codebase Reference

| What                 | Where                                                    |
|----------------------|----------------------------------------------------------|
| Finalize path        | `src/Iidy/Cfn/Operations/TemplateApproval.hs` (lines 172-184) |
| Request path (good)  | `src/Iidy/Cfn/Operations/TemplateApproval.hs` (lines 83-85)   |
| `uploadToS3`         | `src/Iidy/Cfn/Operations/TemplateApproval.hs` (line 208)      |
| `deleteFromS3`       | `src/Iidy/Cfn/Operations/TemplateApproval.hs` (line 232)      |
| `downloadFromS3`     | `src/Iidy/Cfn/Operations/TemplateApproval.hs` (line 218)      |
| Rust finalize        | `~/src/iidy/src/cfn/template_approval_review.rs` (lines 209-246) |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Mechanical fix — replace `_ <-` with `case` checks on `Either`.
  No architectural decisions. The error handling pattern is already
  established in the request path (lines 83-85).

## Progress

- [ ] Fix A: Check S3 upload/delete results in finalize path
- [ ] Fix B: Propagate pending template download failure
- [ ] Build clean + all tests pass

## Handoff Notes

(none yet)
