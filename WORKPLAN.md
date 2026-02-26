# iidy-hs Workplan

**Target**: Feature-complete, behavior-identical, output-identical Haskell port. No shortcuts, no dropped features.
**Status**: Phase 16 (Requirements Documentation) COMPLETE. Phases 1-16 DONE.

Remember, we are writing requirements as if this Haskell version does
not exist yet. DO NOT refer to function names or implementation
details that exist in our code unless they are part of the
non-functional requirements. Do not describe how we built this,
describe its detailed spec. Also do not refer to our implementation
phases / sessions. These are for a human to estimate how long this
repo would take to produce through a detailed understanding of the
requirements, it is not a workplan for them.

Do not include refs to haskell code files in the requirements
docs. Do that in your own working notes/

You forgot this critical detail in the first parts of Phase 16. Cleanup. -- Tavis the human

## Critical Rules

1. **Gate integrity.** Never check off a gate item until verified. Opus must verify completion.
2. **Small, frequent green commits.** Each commit includes corresponding doc updates.
3. **Check .msgs/ constantly.** After every tool call chain or natural pause. Reply to them with {same-name}.reply
   If you use sub-agents remember to have the main agent check .msgs every minute while the sub-agents work.
4. **No phase advancement** until current phase is truly complete and verified.

## Operational Notes

- Git: `git config --local commit.gpgsign false` (YubiKey hangs)
- Build: `cabal jobs: 4`, `-O0` for dev, use `run-quiet` wrapper
- Testing: ALL offline with mock fixtures. No real AWS calls.
- Rust oracle: `~/src/iidy/target/debug/iidy` (via `nix develop ~/src/iidy`)
- Rust snapshots: `~/src/iidy/tests/snapshots/` (98 .snap files)
- Safety: No destructive ops, no files outside ~/src/iidy-hs/, read-only ~/src/iidy/

## Phase Index

| Phase | Description | Status | Doc |
|-------|-------------|--------|-----|
| 16 | Requirements documentation (PRDs + user stories) | **COMPLETE** | [below](#phase-16-requirements-documentation) |

## Phase 16: Requirements Documentation

Generate a **complete** set of PRD / user story documents in `docs/requirements/`
covering the entire iidy-hs feature surface. Retroactive requirements derived from
the implemented Haskell port and its Rust original. No feature or behavior missed.

### PRD Document Set

| #  | File                        | Scope                                                        | Est. Lines |
|----|-----------------------------|--------------------------------------------------------------|------------|
| 00 | `00-overview.md`            | Product overview, personas, design principles, exit codes    | 200        |
| 01 | `01-cli-interface.md`       | 22 commands, global options, help, completions, env vars     | 600        |
| 02 | `02-yaml-preprocessing.md`  | $imports, $defs, 15 tags, handlebars, YAML 1.1/1.2          | 700        |
| 03 | `03-import-system.md`       | 10 import types, security model, resolution, base paths      | 500        |
| 04 | `04-custom-resources.md`    | $params, expansion, ref rewriting, $global, overrides, schema| 500        |
| 05 | `05-cfn-operations.md`      | Stack lifecycle, changesets, polling, diffs, confirmations    | 700        |
| 06 | `06-output-system.md`       | Interactive/JSON/plain, themes, spinners, 26 OutputData types| 500        |
| 07 | `07-error-handling.md`      | 50+ error codes, enhanced display, position tracking, colors | 600        |
| 08 | `08-aws-integration.md`     | Auth chain, credentials, STS, region, profile, assume-role   | 400        |
| 09 | `09-ssm-params.md`          | param set/get/get-by-path/get-history/review, approval       | 400        |
| 10 | `10-template-approval.md`   | S3-based approval, request/review, security model, IAM       | 400        |
| 11 | `11-utilities.md`           | render, explain, completion, demo, init, convert, get-import | 500        |
| 12 | `12-cross-cutting.md`       | YAML 1.1/1.2, NO_COLOR/FORCE_COLOR, TTY, NTP, idempotency   | 400        |

**Total**: ~6,000 lines across 13 documents.

### PRD Template

Each document uses this structure:

```
# PRD: [Title]
## Overview
## User Stories
### US-XX-001: [Short title]
**As a** [persona], **I want to** [action], **so that** [benefit].
**Acceptance Criteria:** (testable, specific)
**Logic Flow:** (step-by-step)
**Edge Cases:** (boundary conditions)
**Error Scenarios:** (error code, message, display)
## Cross-References
```

Personas: **Developer** (deploys stacks, writes templates), **Platform Engineer**
(authors custom resources, manages approvals), **CI Pipeline** (automated, JSON output,
--yes flags), **Reviewer** (reviews template approvals and param changes).

### Source Material

Each PRD draws from these sources (agents must read them, not guess):

| Source              | Location                             |
|---------------------|--------------------------------------|
| User docs           | `docs/*.md`                          |
| Haskell source      | `src/Iidy/` (81 modules)            |
| Rust source         | `~/src/iidy/src/` (read-only)       |
| Test fixtures       | `test/fixtures/`, `test/Test/`       |
| Error fixtures      | `test/fixtures/errors/` (49 files)   |
| Render snapshots    | `test/fixtures/render/`              |
| Rust snapshots      | `~/src/iidy/tests/snapshots/` (98)   |
| Divergences         | `DIVERGENCES.md`                     |
| Dev docs            | `docs/dev/`                          |

### Session Plan

| Session | Deliverables                                         | Delegation                          |
|---------|------------------------------------------------------|-------------------------------------|
| 1       | `00-overview.md` + `01-cli-interface.md`             | Opus main + Sonnet sub for CLI      |
| 2       | `02-yaml-preprocessing.md` + `03-import-system.md`   | 2 Sonnet subs (tags + imports)      |
| 3       | `05-cfn-operations.md` + `06-output-system.md`       | Opus sub (CFN) + Sonnet sub (output)|
| 4       | `07-error-handling.md` + `08-aws-integration.md`     | Opus sub (errors) + Sonnet sub (AWS)|
| 5       | `04-custom-resources.md` + `09-ssm-params.md` + `10-template-approval.md` | Opus + 2 Sonnet subs |
| 6       | `11-utilities.md` + `12-cross-cutting.md`            | Sonnet sub + Opus main              |
| 7       | Completeness review + `COVERAGE.md` traceability     | Explore agents for audit            |
| 8       | Quality gate + final polish + `.ralph-stop`           | Opus main                           |

### Critical Rules for PRD Authors

- Read the **actual source code**, not just docs. Docs may be incomplete.
- However, do not reference the Haskell implementation.
- Every user story needs **acceptance criteria**. No vague stories.
- Every edge case from **test fixtures** must be captured.
- Error scenarios must include the actual **error code** (ERR_XXXX) and message format.
- Cross-references between PRDs must use the actual **file name and section header**.
- Don't invent features. Only document what's implemented.

### Progress

- [x] Session 0: Create workplan + research (Session 40)
- [x] Session 1: `00-overview.md` + `01-cli-interface.md` (Session 41)
- [x] Session 2: `02-yaml-preprocessing.md` + `03-import-system.md` (Session 41)
- [x] Session 3: `05-cfn-operations.md` + `06-output-system.md` (Session 41)
- [x] Session 4: `07-error-handling.md` + `08-aws-integration.md` (Session 41)
- [x] Session 5: `04-custom-resources.md` + `09-ssm-params.md` + `10-template-approval.md` (Session 41)
- [x] Session 6: `11-utilities.md` + `12-cross-cutting.md` (Session 41)
- [x] Cleanup: Strip implementation details from all 13 PRDs, save refs to notes/ (Session 41)
- [x] Session 7: Completeness review + coverage matrix (Session 42).
  - [x] Validate the 'known gap' entries in 03-import-system.md. Result: all 3 gaps legitimate
    (filehash loaders, CFN sub-types, SSM format suffixes). Report: notes/2026-02-25-requirements-gaps-found.md.
  - [x] Add a Ubiquitous Language glossary / reference and ensure we are
    consistent in the terminology we use. Added glossary to 00-overview.md.
  - [x] Ensure all concepts / terms are referenced in each doc have
    already been introduced in the current or preceding documents. Fixed: stack-args.yaml,
    $imports, $defs, $params, render: prefix, environment map, $envValues all introduced in 00.
  - [x] Read each document to ensure someone with only access to the Rust codebase and its documentation plus
    these documents could fully understand the context and requirements. Fixed 8 CRITICAL issues
    and 12+ MODERATE issues across all 13 documents.
  - [x] See README and ensure 00-overview.md captures the essence. Added: Project Lineage section
    with repo links, origin story, AI Agent persona, graduated adoption story, non-CFN use mention.
  - [x] Validate the logic flows for all pseudo code in the documents. Fixed: derived token format
    (both docs 05 and 12), truthiness definition (doc 02), exit codes, NTP packet version.
- [x] Session 8: Quality gate review + final polish + `.ralph-stop` (Session 43).
  - [x] Fixed 6 MODERATE issues from Session 7 handoff notes:
    - describe-stack-drift added to CLI spec (01-cli-interface.md US-01-006b)
    - $params vs ERR_2001 pre-check interaction clarified (04-custom-resources.md)
    - Shell completion zsh/fish distinction clarified (11-utilities.md)
    - Known gap language reframed in 03-import-system.md (requirements vs divergence notes)
    - OutputData type count discrepancy fixed in 06-output-system.md (24 enveloped + 3 special)
    - Target vs current behavior separated in 09-ssm-params.md (divergences in Technical Context)
  - [x] Quality gate pass on remaining PRDs: fixed 3 additional issues
    - 05-cfn-operations.md cross-references updated to filename format
    - 10-template-approval.md lint flag acceptance criterion rewritten
    - 10-template-approval.md S3 error handling language neutralized

### Handoff Notes

#### Session 0 — Workplan Creation (2026-02-25, Session 40)

**Completed**: Created workplan, directory structure, researched full feature surface.
**Research done**: 3 Explore agents inventoried all features from Haskell source (81 modules,
400 tests, 26 OutputData types), Rust source (16,615 LOC, 98 snapshots), and ralph loop
workflow patterns (session structure, handoff format, progress tracking).

#### Session 1 — Overview + CLI PRDs (2026-02-25, Session 41)

**Completed**: Wrote `docs/requirements/00-overview.md` (177 lines) and `docs/requirements/01-cli-interface.md` (742 lines).
**Method**: 2 Explore agents for research (overview + CLI), Sonnet sub-agent wrote CLI PRD from detailed spec.
**Quality**: CLI PRD covers all 22 commands, all flags with defaults, 16 user stories with acceptance criteria. Noted discrepancy between command-reference.md (100 context lines) and Parser.hs (500) for template-approval review.
**Notes for Session 2**: Write `02-yaml-preprocessing.md` + `03-import-system.md`. Use `docs/yaml-preprocessing.md` and `docs/import-types.md` as primary sources, cross-check with `src/Iidy/Yaml/` modules.
**Notes for Session 1**:
- Start with `00-overview.md` — sets the tone and persona definitions used by all other PRDs
- For `01-cli-interface.md`, use `docs/command-reference.md` as primary source, cross-check
  with `src/Iidy/Cli/Parser.hs` for completeness
- Each PRD should be self-contained but cross-reference others by filename
- Sub-agents writing PRDs MUST read source code, not just docs
- Detailed handoff doc with additional context: `notes/handoffs/2026-02-25-requirements-workplan.md`

#### Session 7 — Completeness Review (2026-02-25, Session 42)

**Completed**: Full completeness review of all 13 PRDs.
**Key findings**:
- All 3 known gaps in 03-import-system.md validated as legitimate (filehash, CFN sub-types, SSM format suffixes). Report: `notes/2026-02-25-requirements-gaps-found.md`.
- 00-overview.md enhanced: Project Lineage (repo links), origin story, AI Agent persona, Key Concepts section, Ubiquitous Language glossary.
- Fixed 8 CRITICAL issues: exit code contradictions, truthiness definition, routing path counts, SNTP version, derived token format, broken cross-references.
- Fixed 12+ MODERATE issues: $envValues undefined, explain multi-code, NTP plausibility, AssumeRoleARN, template URL, typos.
**Notes for Session 8**: All 6 MODERATE issues addressed. See Session 8 notes below.

#### Session 8 — Quality Gate + Final Polish (2026-02-25, Session 43)

**Completed**: Quality gate review of all 13 PRDs. Fixed 9 issues total (6 from handoff + 3 from gate pass).
**Key changes**:
- 01-cli-interface.md: Added describe-stack-drift command (US-01-006b), updated command count to 23, fixed OutputData type count language.
- 03-import-system.md: Reframed all "KNOWN GAP" and "Implementation Status" sections as divergence notes. Acceptance criteria now state requirements (what SHOULD happen), not implementation status.
- 04-custom-resources.md: Clarified ERR_2001 pre-check does not fire during custom resource template re-parse.
- 05-cfn-operations.md: Updated cross-references to filename format (not PRD-NN prefix).
- 06-output-system.md: Fixed JSON type name list (24 enveloped names + 3 special-case constructors = 26 total).
- 09-ssm-params.md: Moved all implementation divergences from acceptance criteria to a centralized "Known divergences" section in Technical Context. Acceptance criteria now describe target behavior.
- 10-template-approval.md: Rewrote lint flag acceptance criterion as a requirement, neutralized S3 error language.
- 11-utilities.md: Clarified that bash, zsh, and fish all receive bash-format completion output (optparse-applicative limitation).
**Phase 16 COMPLETE.** All 13 PRDs are final.

## Session Log

| Session | Phase | Summary |
|---------|-------|---------|
...
| 40 | 16 | Phase 16 setup: Requirements documentation workplan. 13 PRDs planned, 8-session plan, 3 research agents. |
| 41 | 16 | All 13 PRDs written (~9,500 lines). Cleaned to remove implementation details per user feedback. |
| 42 | 16 | Session 7: Completeness review. Validated 3 gaps (all legitimate). Enhanced 00-overview. Fixed 8 CRITICAL + 12 MODERATE issues. |
| 43 | 16 | Session 8: Quality gate + final polish. Fixed 9 issues across 8 PRDs. Phase 16 COMPLETE. |

