# Staircase Nesting Review Findings

**Date**: 2026-03-03
**Scope**: Files from `notes/handoffs/2026-03-02-staircase-review.md`

---

## Summary

Audited 7 files for 4+ level deep case-of staircase patterns. Found significant
nesting in 2 files; remaining files are already acceptable or already clean.

---

## Files Audited

### 1. `src/Iidy/Cfn/Operations/TemplateApproval.hs` — FIXED

**`templateApprovalRequest`** had 6 levels of case nesting:
- L65: `case saApprovedTemplateLocation sa`
- L68: `case saTemplate sa`
- L73: `case tmplEither`
- L75: `case trTemplateBody tmplResult`
- L80: `case generateVersionedLocation ...`
- L102: `case uploadResult`

**`templateApprovalReview`** had deep nesting in the approval path:
- L131: `case parseS3Url url`
- L174: `case pendingTemplate`
- L208: `case uploadApproved`
- L211: `case uploadLatest`
- L215: `case deleteResult`

**Fix applied**: Converted both functions to `ExceptT Text IO` using `runExceptT`.
Extracted inner logic to `reviewPendingTemplate` and `approveTemplate` helpers.
Added `liftExceptT`, `liftEitherT`, `liftMaybe`, and `prefixError` local helpers.

---

### 2. `src/Iidy/Cfn/StackArgsLoader.hs` — FIXED

**`loadStackArgs`** had 4 levels of case nesting:
- L110: `case parseYaml content baseLocation`
- L117: `case result` (preprocessYaml11)
- L123: `case resolveEnvMaps jsonVal environment`
- L142: `case valueToStackArgs withEnvValues`

**Fix applied**: Converted to `ExceptT Text IO` with `runExceptT`. Each
`Either`-returning step uses `throwE` for errors and `pure` for success. The
IO actions use `lift` or `ExceptT` wrapping.

---

### 3. `src/Iidy/Cfn/Operations/Changeset.hs` — OK

No deep staircase patterns. `createChangeset` has a single `case reqResult` (2 levels),
`pollChangesetCompletion` uses guards effectively. Clean.

---

### 4. `src/Iidy/Cfn/Operations/CreateOrUpdate.hs` — OK

Clean dispatch: top-level `case (exists, useChangeset)` routes to 4 helpers.
Each helper has at most 2 case levels. No staircase.

---

### 5. `src/Iidy/Cfn/Operations/DeleteStack.hs` — OK

`deleteStack` has one meaningful case split (`mStack`), then linear IO with
a confirmation guard. No staircase pattern.

---

### 6. `src/Iidy/Params/Client.hs` — MINOR (acceptable)

`paramGet` has a 3-level nesting (format dispatch -> fetch -> tags). Acceptable;
the logic is clear and the nesting matches the data flow naturally.

`paramGetHistory` was previously the worst offender (7 levels) and has already
been refactored. Current version is clean.

---

### 7. `app/Main.hs` — OK

Command dispatch is a flat `case cliCommand cli`. Each arm is short and
delegates to helpers. No staircase patterns.

---

## Fix Plan (completed)

1. **TemplateApproval.hs**: Refactored both `templateApprovalRequest` and
   `templateApprovalReview` using `ExceptT Text IO`. Extracted inner logic to
   `reviewPendingTemplate` and `approveTemplate` helpers.

2. **StackArgsLoader.hs**: Refactored `loadStackArgs` using `ExceptT Text IO`.
   Pure `Either` results use `throwE`; IO actions use `lift` or `ExceptT`.
