# template-approval: Output Sequencing Analysis

## template-approval request

### Rust Output Sequence

```
1. CommandMetadata
2. [If already approved]:
   2a. ApprovalRequestResult(already_approved=true)  — "Your template has already been approved"
   2b. return 0
3. [If --lint-template]:
   3a. TemplateValidation                            — errors/warnings
   3b. [If errors, return 1]
4. [Upload pending template to S3]
5. ApprovalRequestResult(already_approved=false)     — pending location + next steps
```

Expected sections: `["command_metadata", "template_validation", "approval_request_result"]`

### Haskell Output Sequence (Current)

```
(no OutputData — all direct stdout via TIO.putStrLn)
Line 71: "Template already approved at s3://..."
Line 80: "Pending template uploaded to s3://..."
Line 81: "Review with: iidy-hs template-approval review s3://..."
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | MEDIUM |
| 2 | Rendering via ApprovalRequestResult OutputData | MEDIUM — plain text vs styled |
| 3 | TemplateValidation when --lint-template | MEDIUM |
| 4 | Next steps formatting | LOW |

---

## template-approval review

### Rust Output Sequence

```
1. CommandMetadata
2. ApprovalStatus                                — pending exists, locations
3. [If already approved]: return 0
4. TemplateDiff                                  — unified diff
5. [If no changes]:
   5a. ApprovalResult(approved=true)
   5b. return 0
6. ConfirmationPrompt ("Would you like to approve?")
7. [If approved]:
   7a. ApprovalResult(approved=true)
8. [If rejected]:
   8a. ApprovalResult(approved=false)
```

Expected sections: `["command_metadata", "approval_status", "template_diff", "confirmation", "approval_result"]`

### Haskell Output Sequence (Current)

```
(no OutputData — all direct stdout via TIO.putStrLn)
Line 121: "Template already approved at s3://..."
Line 135: "No changes detected."
Line 138: "Template diff:"
Line 139: diffOutput
Line 142: requestConfirmation prompt
Line 149: "Template approved at s3://..."
Line 152: "Template not approved."
```

### Missing in Haskell

| # | Missing | Severity |
|---|---------|----------|
| 1 | CommandMetadata | MEDIUM |
| 2 | ApprovalStatus rendering | MEDIUM — plain text vs styled sections |
| 3 | TemplateDiff via OutputData | MEDIUM — works but unstyled |
| 4 | ApprovalResult via OutputData | LOW — status is shown |
| 5 | Diff quality | MEDIUM — Haskell uses naive set-diff, Rust likely uses proper unified diff |

### Fix Plan (Both Commands)

1. Change both functions to accept `emit` callback or return `[OutputData]`
2. Use existing renderer functions (renderApprovalRequestResult, renderApprovalStatus,
   renderTemplateDiff, renderApprovalResult) — all already implemented in Interactive.hs
3. The renderers exist but are never called because the operations bypass OutputData

### Relevant Code

- **Rust request**: `~/src/iidy/src/cfn/template_approval_request.rs` lines 16-109
- **Rust review**: `~/src/iidy/src/cfn/template_approval_review.rs` lines 14-157
- **Haskell**: `src/Iidy/Cfn/Operations/TemplateApproval.hs` lines 42-153
- **Renderers**: `src/Iidy/Output/Renderers/Interactive.hs` lines 778-838
