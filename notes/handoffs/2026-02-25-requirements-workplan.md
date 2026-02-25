# Requirements Documentation -- Multi-Session Workplan

**Date**: 2026-02-25
**Session**: `e67ca969-1c4d-4ab4-b023-825844ff2c32`
**References**: `docs/` (user-facing docs), `DIVERGENCES.md`, `WORKPLAN.md`, `src/Iidy/` (81 modules), `~/src/iidy/` (Rust source, read-only)

## Context

Generate a **complete** set of PRD / user story documents in `docs/requirements/`
covering the entire iidy-hs feature surface. These are retroactive requirements
docs derived from the implemented Haskell port and its Rust original.

Each document must include:
- **User stories** (As a [persona], I want [action], so that [benefit])
- **Acceptance criteria** (testable, specific)
- **Logic flows** (step-by-step behavior for each operation)
- **Edge cases** (boundary conditions, empty inputs, missing data)
- **Error scenarios** (what fails, how, what the user sees)
- **Cross-references** to other PRDs where behaviors interact

Personas:
- **Developer**: Deploys CloudFormation stacks, writes templates, uses preprocessing
- **Platform Engineer**: Authors custom resource templates, manages approval workflows
- **CI Pipeline**: Automated non-interactive execution (JSON output, --yes flags)
- **Reviewer**: Reviews template approvals and parameter changes

## PRD Document Set

13 documents covering the full feature surface:

| # | File | Scope | Est. Lines |
|---|------|-------|------------|
| 00 | `00-overview.md` | Product overview, personas, design principles, exit codes | 200 |
| 01 | `01-cli-interface.md` | 22 commands, global options, help, completions, env vars | 600 |
| 02 | `02-yaml-preprocessing.md` | $imports, $defs, 15 tags, handlebars, YAML 1.1/1.2 | 700 |
| 03 | `03-import-system.md` | 10 import types, security model, resolution, base paths | 500 |
| 04 | `04-custom-resources.md` | $params, expansion, ref rewriting, $global, overrides, schema | 500 |
| 05 | `05-cfn-operations.md` | Stack lifecycle, changesets, polling, diffs, confirmations | 700 |
| 06 | `06-output-system.md` | Interactive/JSON/plain, themes, spinners, 26 OutputData types | 500 |
| 07 | `07-error-handling.md` | 50+ error codes, enhanced display, position tracking, colors | 600 |
| 08 | `08-aws-integration.md` | Auth chain, credentials, STS, region, profile, assume-role | 400 |
| 09 | `09-ssm-params.md` | param set/get/get-by-path/get-history/review, approval workflow | 400 |
| 10 | `10-template-approval.md` | S3-based approval, request/review, security model, IAM | 400 |
| 11 | `11-utilities.md` | render, explain, completion, demo, init, convert, get-import, lint | 500 |
| 12 | `12-cross-cutting.md` | YAML 1.1/1.2, NO_COLOR/FORCE_COLOR, TTY detection, NTP, idempotency | 400 |

**Total**: ~6,000 lines across 13 documents.

## Source Material

Each PRD draws from these sources (agents must read them, not guess):

| Source | Location | Purpose |
|--------|----------|---------|
| User docs | `docs/*.md` | Documented behavior (command-reference, yaml-preprocessing, import-types, getting-started, custom-resource-templates, SECURITY.md) |
| Haskell source | `src/Iidy/` (81 modules) | Implementation details, edge cases, error paths |
| Rust source | `~/src/iidy/src/` (read-only) | Original behavior reference |
| Test fixtures | `test/fixtures/`, `test/Test/` | Edge cases, error examples |
| Error fixtures | `test/fixtures/errors/` | 49 error condition files |
| Render snapshots | `test/fixtures/render/` | Expected output examples |
| Rust snapshots | `~/src/iidy/tests/snapshots/` | 98 snapshot files for behavior reference |
| Divergences | `DIVERGENCES.md` | Known differences from Rust |
| Dev docs | `docs/dev/` | Architecture, output pipeline, AWS config, testing |

## Session Plan

### Session 1: Structure + First Batch (this session → next)
- [x] Create `docs/requirements/` directory
- [x] Create this workplan + handoff doc
- [ ] Write `00-overview.md` (overview, personas, principles)
- [ ] Write `01-cli-interface.md` (all 22 commands, global options)
- Commit: "Add requirements documentation structure and CLI/overview PRDs"

### Session 2: YAML Preprocessing + Imports
- [ ] Write `02-yaml-preprocessing.md` (all 15 tags, handlebars, YAML versions)
- [ ] Write `03-import-system.md` (10 import types, security, resolution)
- Use sub-agents: one for preprocessing tags research, one for import types research
- Commit: "Add YAML preprocessing and import system PRDs"

### Session 3: CFN Operations + Output System
- [ ] Write `05-cfn-operations.md` (all stack ops, changesets, polling, diffs)
- [ ] Write `06-output-system.md` (renderers, themes, 26 OutputData types, spinner)
- Use sub-agents: one reading CFN ops source, one reading output source
- Commit: "Add CloudFormation operations and output system PRDs"

### Session 4: Error Handling + AWS Integration
- [ ] Write `07-error-handling.md` (50+ codes, enhanced display, colors)
- [ ] Write `08-aws-integration.md` (auth chain, credentials, region)
- Use sub-agents: one reading error source + fixtures, one reading AWS source
- Commit: "Add error handling and AWS integration PRDs"

### Session 5: Custom Resources + Template Approval + SSM
- [ ] Write `04-custom-resources.md` (params, expansion, ref rewriting)
- [ ] Write `09-ssm-params.md` (param CRUD, approval workflow)
- [ ] Write `10-template-approval.md` (S3 approval, IAM model)
- Commit: "Add custom resources, SSM params, and template approval PRDs"

### Session 6: Utilities + Cross-Cutting
- [ ] Write `11-utilities.md` (render, explain, demo, init, convert, etc.)
- [ ] Write `12-cross-cutting.md` (YAML versions, color env vars, NTP, idempotency)
- Commit: "Add utilities and cross-cutting concerns PRDs"

### Session 7: Completeness Review
- [ ] Run feature inventory audit: every Haskell module → covered by which PRD?
- [ ] Run test fixture audit: every error fixture → mentioned in which PRD?
- [ ] Run command audit: all 22 commands → all flags documented in PRDs?
- [ ] Run tag audit: all 15 preprocessing tags → covered with edge cases?
- [ ] Fill gaps found by audit
- [ ] Create `docs/requirements/COVERAGE.md` — traceability matrix
- Commit: "Completeness audit: coverage matrix and gap fills"

### Session 8: Quality Gate + Final Polish
- [ ] Cross-reference consistency: verify all PRD cross-links are valid
- [ ] Terminology consistency: same terms used across all docs
- [ ] Acceptance criteria audit: every AC is testable and specific
- [ ] Edge case coverage: compare against test fixtures
- [ ] Final commit: "Quality gate pass: requirements documentation complete"
- Touch `.ralph-stop` to signal completion

## PRD Template

Each document follows this structure:

```markdown
# PRD: [Title]

## Overview
[1-2 paragraph summary of this feature area]

## User Stories

### US-XX-001: [Short title]
**As a** [persona], **I want to** [action], **so that** [benefit].

**Acceptance Criteria:**
- [ ] AC1: [specific, testable criterion]
- [ ] AC2: ...

**Logic Flow:**
1. Step 1
2. Step 2 (if condition → step 2a, else → step 2b)
3. ...

**Edge Cases:**
- [condition] → [expected behavior]
- ...

**Error Scenarios:**
- [error condition] → [error code, message, display]
- ...

---

### US-XX-002: ...

## Cross-References
- [Link to related PRD sections]
```

## Delegation Strategy

| Session | Work Item | Delegate? | Agent Type | Notes |
|---------|-----------|-----------|------------|-------|
| 1 | Overview PRD | Opus main | — | Sets tone/template for all others |
| 1 | CLI PRD | Sonnet sub-agent | general-purpose | Mechanical: enumerate commands from docs |
| 2 | Preprocessing PRD | Sonnet sub-agent | general-purpose | Read yaml-preprocessing.md + source |
| 2 | Import system PRD | Sonnet sub-agent | general-purpose | Read import-types.md + SECURITY.md + source |
| 3 | CFN ops PRD | Opus sub-agent | general-purpose | Complex: polling, changesets, 5 paths |
| 3 | Output system PRD | Sonnet sub-agent | general-purpose | Read output types + renderers |
| 4 | Error handling PRD | Opus sub-agent | general-purpose | Complex: 50+ codes, display system |
| 4 | AWS integration PRD | Sonnet sub-agent | general-purpose | Read AWS config + auth chain |
| 5 | Custom resources PRD | Opus sub-agent | general-purpose | Complex: expansion, ref rewriting |
| 5 | SSM params PRD | Sonnet sub-agent | general-purpose | Mechanical: 5 param commands |
| 5 | Template approval PRD | Sonnet sub-agent | general-purpose | Read docs + source |
| 6 | Utilities PRD | Sonnet sub-agent | general-purpose | Mechanical: enumerate utilities |
| 6 | Cross-cutting PRD | Opus main | — | Requires understanding all systems |
| 7 | Completeness review | Explore sub-agents | Explore | Feature inventory vs PRD coverage |
| 8 | Quality gate | Opus main | — | Final review and polish |

## Workflow Instructions

Each session in the ralph loop should:

1. **Read this file first** (`notes/handoffs/2026-02-25-requirements-workplan.md`)
2. **Check Progress** below to see what's next
3. **Check `.msgs/`** for any priority changes from user
4. **Read the PRD template** section above for structure
5. **Dispatch sub-agents** for research + drafting where noted
6. **Review sub-agent output** — ensure completeness, no missed features
7. **Commit** with descriptive message
8. **Update Progress** below and add Handoff Notes
9. **Update `progress.log`** with single-line entry
10. **Exit cleanly** for next session

**Critical rules for sub-agents writing PRDs:**
- Read the ACTUAL SOURCE CODE, not just docs. Docs may be incomplete.
- Every user story needs acceptance criteria. No vague stories.
- Every edge case from test fixtures must be captured.
- Error scenarios must include the actual error code (ERR_XXXX) and message format.
- Cross-references between PRDs must use the actual file name and section header.
- Don't invent features. Only document what's implemented.

## Progress

- [x] Session 0: Create workplan + handoff doc
- [ ] Session 1: `00-overview.md` + `01-cli-interface.md`
- [ ] Session 2: `02-yaml-preprocessing.md` + `03-import-system.md`
- [ ] Session 3: `05-cfn-operations.md` + `06-output-system.md`
- [ ] Session 4: `07-error-handling.md` + `08-aws-integration.md`
- [ ] Session 5: `04-custom-resources.md` + `09-ssm-params.md` + `10-template-approval.md`
- [ ] Session 6: `11-utilities.md` + `12-cross-cutting.md`
- [ ] Session 7: Completeness review + coverage matrix
- [ ] Session 8: Quality gate + final polish + `.ralph-stop`

## Handoff Notes

### Session 0 — Workplan Creation (2026-02-25)

**Session**: `e67ca969-1c4d-4ab4-b023-825844ff2c32`
**Completed**: Created workplan, directory structure, researched full feature surface
**Files created**: `notes/handoffs/2026-02-25-requirements-workplan.md`, `docs/requirements/` dir
**Research done**:
- Read all 6 user-facing docs (command-reference, yaml-preprocessing, import-types, getting-started, custom-resource-templates, SECURITY.md)
- Read DIVERGENCES.md, WORKPLAN.md, RALPH.md
- Dispatched 3 Explore agents: Haskell codebase inventory, Rust source inventory, ralph loop workflow patterns
- Inventoried: 22 commands, 15 preprocessing tags, 10 import types, 28 handlebars helpers, 50+ error codes, 26 OutputData types, 81 modules
**Notes for next session**:
- Start with `00-overview.md` — sets the tone and persona definitions used by all other PRDs
- For `01-cli-interface.md`, use `docs/command-reference.md` as primary source, cross-check with `src/Iidy/Cli/Parser.hs` for completeness
- Each PRD should be self-contained but cross-reference others by filename
- Sub-agents writing PRDs MUST read source code, not just docs
