# Requirements Gaps Report — 2026-02-25

## Known Gap Validation (03-import-system.md)

The WORKPLAN.md asked: "The human believes Claude already addressed cfn sub-type imports.
This may have come from a stale document. Check the code."

**Result: All three gaps in 03-import-system.md are legitimate.** None have been addressed.

### Gap 1: `filehash:` / `filehash-base64:` import loaders

- **Status**: LEGITIMATE GAP
- Types are defined in `ImportType` (`ImportFilehash`, `ImportFilehashBase64`)
- Security model correctly classifies them as local-only
- **No loader exists** — no `Loaders/Filehash.hs` file
- Handlebars helpers `filehash`/`filehashBase64` work (Helpers.hs:64-65, 271-331)
- Only the `$imports` pipeline path is missing
- Rust: `load_filehash_import` in `loaders/file.rs:101-155`

### Gap 2: CFN sub-types (`cfn:output:`, `cfn:export:`, etc.)

- **Status**: LEGITIMATE GAP
- Haskell CFN loader (`Loaders/Cfn.hs`, 104 lines) only handles legacy `cfn:stack/key` and `cfn:stack.key`
- No sub-type prefix parsing (`output:`, `export:`, `parameter:`, `tag:`, `resource:`, `stack:`)
- No AWS APIs for ListExports, ListStackResources, etc.
- Rust: Full implementation in `loaders/cfn.rs` (1113 lines, all 6 sub-types)

### Gap 3: SSM format suffixes (`:json`, `:yaml`) and `ssm-path:`

- **Status**: LEGITIMATE GAP
- Haskell SSM loader (`Loaders/Ssm.hs`, 56 lines) passes format suffix as part of param name
- No format-based parsing of returned values
- No `ssm-path:` loader (`GetParametersByPath` API not called)
- Rust: Full implementation in `loaders/ssm.rs` (408 lines)

### Structural Gap: No Multi-Type Import Dispatcher

All preprocessing call sites pass `loadFileImport` as the sole import loader:
- `Render.hs:64`, `StackArgsLoader.hs:76`, `Demo.hs:72`
- Individual loaders for env, git, random, http, s3, cfn, ssm exist but are unreachable from `$imports`
- Rust has `ProductionImportLoader` (`loaders/mod.rs:34-98`) as a unified dispatcher

## Cross-Document Issues Found

### CRITICAL: Exit Code Contradiction

Three different exit codes for user declining a confirmation prompt:

| Document                  | Exit Code | Status        |
|---------------------------|-----------|---------------|
| 00, 01, 05, 07, 09       | 130       | **CORRECT**   |
| 10-template-approval.md   | 1         | **INCORRECT** |
| 12-cross-cutting.md       | 0         | **INCORRECT** |

Verified against code: `Confirm.hs` callers all return `Right 130`. Help text says
"Cancelled (130) — User responded 'No' to prompt or sent CTRL-C".

### Terminology Inconsistencies

1. **AssumeRoleArn vs AssumeRoleARN** — doc 01 uses `Arn`, doc 08 uses `ARN`. Canonical: `AssumeRoleARN`
2. **7 terms for Rust reference** — standardize on "Rust oracle" (behavioral), "Rust binary" (file)
3. **"template body" vs "template content"** — standardize on "template body" (matches AWS API)
4. **"environment" overloaded** — variable environment vs deployment environment vs environment map

### Forward References

1. **stack-args.yaml** — used in 00-overview.md line 43 with no definition. Needs Key Concepts section.
2. **$imports/$defs** — used in 00 line 44 without gloss
3. **$params** — used in 00 line 25 before doc 04 defines it
4. **render: prefix** — used in 00 line 46 without definition
5. **environment map** — first defined in doc 08, used implicitly in 00/01
6. **OutputData types** — used extensively in doc 05 before doc 06 defines them

### Missing from 00-overview.md

1. No project lineage (TypeScript → Rust → Haskell)
2. No repo links (Rust: tavisrudd/iidy, TS: unbounce/iidy)
3. No AI agent persona
4. No origin story / "why iidy exists"
5. No "works with plain CFN templates" graduated adoption story
6. No non-CloudFormation use mention (K8s manifests, CI configs via `render`)
