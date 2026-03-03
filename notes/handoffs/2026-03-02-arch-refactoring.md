# Architecture Refactoring: Review, Elaborate, Spike

**Date**: 2026-03-02
**Status**: ON HOLD — low-hanging fruit done, bigger refactors deferred pending decision
**References**: `notes/2026-03-02-refactoring-plan.md`, six review files in `notes/2026-03-02-*-review.md`

## Context

Session 44 produced six architecture reviews (Hickey, Ousterhout, Minsky, Krishnamurthi,
Kmett, Muratori) and synthesized them into a 10-phase refactoring plan with ~17 green
commits. The plan is written but needs:

1. **Critical review** — does the plan miss anything? Are the risk levels accurate?
   Are any steps mis-ordered or under-scoped?
2. **Elaboration** — several steps need concrete type signatures, module placements,
   and migration strategies spelled out before implementation.
3. **Spikes** — small proof-of-concept implementations for the riskier phases to
   validate the approach before committing to it.

## Instructions for Next Agent

**This is a research + spike session, not a full implementation session.**

Read the refactoring plan (`notes/2026-03-02-refactoring-plan.md`) and all six review
files thoroughly. Then work through the chunks below in order. Each chunk either
produces analysis (written to the plan or a new notes file) or a spike (a small
code change that validates feasibility, then reverted or committed as appropriate).

Keep main context clean — delegate reads of the review files and Rust source
exploration to sub-agents.

## Critique of the Plan (from Session 44 author)

Read these before starting Chunk 1 — they should inform your gap analysis.
**This is one perspective.** Chunk 1 should produce *multiple independent critiques*
of the plan from different angles — not just elaborate on these points. Consider
critiquing from at least:

- **A pragmatist/maintainer angle**: What will actually matter in 6 months? Which
  phases are pure aesthetics vs. preventing real bugs?
- **A risk/sequencing angle**: Are the dependencies right? Could a phase fail
  catastrophically and block everything downstream?
- **A Rust-parity angle**: Do any refactorings silently change observable behavior
  vs. the Rust implementation? The plan says "no snapshot impact" a lot — verify this.
- **A "what's missing" angle**: The plan addresses what the reviews flagged. But the
  reviews themselves had blind spots (they were generated from code exploration, not
  from using the tool). What would a *user* of iidy want improved?
- **A cost-benefit angle**: 17 commits touching ~40 files is a lot of churn. Is the
  payoff proportional? Which phases could be dropped entirely with minimal loss?

The notes below are the session 44 author's self-critique — one voice, not the final word.

1. **Conservative to a fault.** The exclusions list (no MTL, no optics, no module
   merging, no free monads) preemptively closes off the highest-leverage improvements
   Kmett identified. The plan treats "port fidelity" as a permanent constraint, but
   at some point this codebase needs to stop being "the Rust port" and start being
   "the Haskell implementation." The plan has no phase for that transition. Consider
   whether any excluded items should be reconsidered — particularly `ReaderT CfnEnv IO`
   which would eliminate the pass-through threading that Ousterhout flagged.

2. **Phase 2 (StackStatus) underestimates blast radius.** "~18 files" is probably 25+
   once you count test builders, integration tests, fixture constructors, and operation
   modules. The plan says "mechanical" but threading a new type through 27 output record
   types each with a `Text` status field is a full session's work. The spike in Chunk 3
   should measure the real scope before committing.

3. **Phase 6 (Krishnamurthi testing) is the most valuable phase but buried at position
   6.** Semantic property tests would find real bugs *today*. The enum refactorings
   (Phases 1-2) are correctness improvements for *future* code that nobody has written
   wrong yet. Consider recommending Phase 6 be promoted to run first or in parallel
   with Phase 1.

4. **Phase 7.2 (StackArgs validation) is vague.** "Check what Rust does with
   contradictory fields" is research, not a plan. This handoff covers it in Chunk 1,
   but the plan itself should say "skip until Rust behavior is verified" rather than
   presenting it as ready to implement.

5. **The plan doesn't address Muratori's core point.** Muratori's review wasn't about
   refactoring — it was about whether 85 modules and 15k LOC are justified by the
   problem. The plan adds *more* types, *more* modules, *more* tests. It makes the
   architecture prettier but doesn't make it smaller. Think about whether any phases
   could be paired with complexity *reduction* (e.g., Phase 5 replaces OdRawOutput
   with 2 new constructors — could it also remove OdRawOutput entirely?).

6. **Missing: `!$expand` cycle detection.** Krishnamurthi flagged that `!$expand` has
   no recursion guard (the import system has `ImportStack` for cycle detection, but
   template expansion doesn't). This is a latent infinite loop bug. No phase addresses
   it. Consider adding it — it's a small, high-value fix (add a `Set Text` of active
   expansions, check before re-parsing).

7. **Missing: the `unsafePerformIO` global HTTP manager.** Hickey and Minsky both
   flagged the `globalManagerRef` in `Http.hs`. The plan doesn't address it. It's low
   priority (the pattern is conventional Haskell) but should at least be acknowledged
   in the plan as a conscious exclusion.

8. **Missing: Render.hs direct stderr writes.** Phase 8.1 routes `Sts.hs` warnings
   through the pipeline, but `Render.hs` also writes errors directly to stderr
   bypassing the output pipeline. The plan mentions this in Phase 8.2 as "document
   the exception" but doesn't fix it. Consider whether `Render.hs` error paths should
   also go through `emit`.

## Codebase Reference

| What                           | Where                                                                     |
|--------------------------------|---------------------------------------------------------------------------|
| Refactoring plan               | `notes/2026-03-02-refactoring-plan.md`                                    |
| Hickey review (complecting)    | `notes/reviews/2026-03-02-review--architecture-persona:hickey.md`         |
| Ousterhout review (depth)      | `notes/reviews/2026-03-02-review--architecture-persona:ousterhout.md`     |
| Minsky review (illegal states) | `notes/reviews/2026-03-02-review--architecture-persona:minsky.md`         |
| Krishnamurthi review (PL)      | `notes/reviews/2026-03-02-review--architecture-persona:krishnamurthi.md`  |
| Kmett review (type machinery)  | `notes/reviews/2026-03-02-review--architecture-persona:kmett.md`          |
| Muratori review (proportional) | `notes/reviews/2026-03-02-review--architecture-persona:muratori.md`       |
| StackArgs type                 | `src/Iidy/Cfn/Types.hs`                                                   |
| CfnContext type                | `src/Iidy/Cfn/Context.hs`                                                 |
| OutputData type                | `src/Iidy/Output/Types.hs`                                                |
| StackArgsLoader                | `src/Iidy/Cfn/StackArgsLoader.hs`                                         |
| RequestBuilder                 | `src/Iidy/Cfn/RequestBuilder.hs`                                          |
| StackOperations (PollConfig)   | `src/Iidy/Cfn/StackOperations.hs`                                         |
| TemplateLoader                 | `src/Iidy/Cfn/TemplateLoader.hs`                                          |
| JMESPath                       | `src/Iidy/Yaml/JMESPath.hs`                                               |
| Main.hs                        | `app/Main.hs`                                                              |
| Resolver                       | `src/Iidy/Yaml/Resolution/Resolver.hs`                                     |
| Rust source (read-only)        | `~/src/iidy/`                                                              |
| Rust RequestBuilder             | `~/src/iidy/src/cfn/request_builder.rs`                                    |
| Rust StackArgs                  | `~/src/iidy/src/cfn/stack_args.rs`                                         |

## Chunks

### Chunk 1: Plan Review & Multi-Angle Critique
**Goal**: Read the plan critically from multiple perspectives. Write findings to
`notes/2026-03-02-plan-review.md` organized by critique angle.

Read the "Known Weaknesses" section above first, then produce your *own* independent
critiques. Don't just agree with or elaborate on the session 44 notes — challenge
them where warranted.

**Factual verification (any angle):**
- [ ] Read all six reviews + the refactoring plan
- [ ] Does Phase 1 (enums) correctly identify all stringly-typed values?
      Search for other `Text` fields that should be enums (e.g., `saResourceTypes`,
      changeset execution status, drift status)
- [ ] Does Phase 2 (StackStatus) account for resource-level vs stack-level statuses?
- [ ] Does Phase 4 correctly identify all users of fields being removed?
      Grep for `cfnCredentialSources` and `cfnOperation` exhaustively
- [ ] What does Rust do with contradictory StackArgs fields (Phase 7.2)?

**Pragmatist/maintainer critique:**
- [ ] Which phases prevent real bugs vs. satisfy aesthetic preferences?
- [ ] Which phases will a future contributor actually thank you for?
- [ ] Which phases create maintenance burden (new types to keep in sync, new
      tests to update on every change)?

**Risk/sequencing critique:**
- [ ] Are the dependency arrows correct? Could Phase 2.2 be harder than estimated?
- [ ] What's the worst-case failure mode for each phase?
- [ ] Are there phases that should be split smaller or merged together?

**Rust-parity critique:**
- [ ] Do any refactorings change observable behavior? The plan assumes not —verify.
- [ ] Will snapshot tests catch regressions from these changes? Or are there
      behavioral paths not covered by snapshots?

**"What's missing" critique:**
- [ ] Compare each review's full recommendation list against the plan's phases.
      What did the plan omit? Was the omission justified?
- [ ] The reviews were code-driven, not usage-driven. What would a *user* flag?

**Cost-benefit critique:**
- [ ] 17 commits, ~40 files. Is this proportional to the value?
- [ ] Which phases could be dropped with <10% loss of value?
- [ ] Is there a "Phase 0" — a single high-impact change worth more than all 10?

- [ ] Write all findings to `notes/2026-03-02-plan-review.md`, organized by angle

### Chunk 2: Spike — OnFailure + Capability Enums (Phase 1.1-1.2)
**Goal**: Validate that introducing enums into StackArgs is non-breaking.

- [ ] Create the `OnFailure` and `Capability` types in `Cfn/Types.hs`
- [ ] Change `StackArgs` field types
- [ ] Fix all compiler errors (follow the types)
- [ ] Run `cabal build` — does it compile cleanly with zero warnings?
- [ ] Run `cabal test` — do all 958 tests pass?
- [ ] Run `scripts/snapshot-compare.sh` — do all 37 snapshots match?
- [ ] Note any surprises (unexpected callers, tricky conversions, test fixtures
      that hardcode Text values)
- [ ] If clean: commit as Phase 1.1+1.2
- [ ] If issues found: document them in the plan review file, revert

### Chunk 3: Spike — StackStatus Type (Phase 2.1)
**Goal**: Validate introducing a StackStatus sum type at the boundary.

- [ ] Enumerate all CloudFormation stack statuses from amazonka source
- [ ] Create the sum type with `parseStackStatus` and `stackStatusToText`
- [ ] Replace `allTerminalStatuses :: [Text]` with `[StackStatus]`
- [ ] Update `Cfn.Status` classification functions
- [ ] Run `cabal build` + `cabal test` — check for breakage
- [ ] Assess scope: how many files does Phase 2.2 (threading through output) touch?
      Is the plan's "~12-15 files" estimate accurate?
- [ ] If clean: commit as Phase 2.1
- [ ] If issues found: document, revert

### Chunk 4: Spike — TemplateLoader fail->Either (Phase 3)
**Goal**: Quick validation — this should be the simplest spike.

- [ ] Read `TemplateLoader.hs`, identify all `fail` call sites
- [ ] Change return type, replace `fail` with `Left`
- [ ] Fix callers (should be 1-2 in `RequestBuilder.hs`)
- [ ] Run `cabal build` + `cabal test`
- [ ] If clean: commit as Phase 3.1
- [ ] If issues found: document, revert

### Chunk 5: Elaborate — CfnContext Separation (Phase 4)
**Goal**: Design the split without implementing. Write to plan review file.

- [ ] Grep every use of `cfnCredentialSources` — confirm exactly 1 use site
- [ ] Grep every use of `cfnOperation` — confirm limited use
- [ ] Grep every use of `cfnUsedTokens` — which operations actually derive tokens?
- [ ] Draft the `CfnReadContext` / `CfnWriteContext` types with exact fields
- [ ] List every function signature that changes (with old and new signatures)
- [ ] Estimate: is Phase 4.2 (read/write split) worth the churn? Or is 4.1 enough?
- [ ] Write the design to the plan review file

### Chunk 6: Elaborate — Semantic Property Tests (Phase 6.1)
**Goal**: Draft the specific property test implementations.

- [ ] Read `test/Test/PropertyTest.hs` for existing patterns and generators
- [ ] Read `Resolver.hs` to understand how to construct test ASTs programmatically
- [ ] Draft 8-10 specific property test bodies (merge right-bias, map length,
      concat associativity, let scoping, if branch selection, idempotency,
      CFN tag pass-through, !$/{{}} equivalence)
- [ ] For each: what generators are needed? Can we reuse existing ones?
- [ ] Write the draft tests to the plan review file (code blocks, not committed)

### Chunk 7: Elaborate — JMESPath Subset (Phase 6.2)
**Goal**: Precisely document what's implemented vs. not.

- [ ] Read `src/Iidy/Yaml/JMESPath.hs` — list every `JExpr` constructor
- [ ] Read the JMESPath spec at jmespath.org — list every expression form
- [ ] Cross-reference: what's covered, what's missing
- [ ] Check: does the Rust `jmespath` crate support functions? Does any
      iidy test fixture use JMESPath functions?
- [ ] Draft the `notes/jmespath-subset.md` content
- [ ] Draft the improved parser error messages for unsupported features

### Chunk 8: Wrap Up
**Goal**: Commit all analysis and any successful spikes.

- [ ] Ensure `notes/2026-03-02-plan-review.md` has all findings
- [ ] Update `notes/2026-03-02-refactoring-plan.md` with any corrections
      discovered during spikes (scope estimates, risk levels, missing steps)
- [ ] Commit all changes
- [ ] Update progress.log

## Progress

Session 45 diverged from the chunk plan above after reviewing all six reviews and the
refactoring plan. Instead of executing the review/spike chunks as written, the session:

1. Wrote a multi-angle critique of the plan (`notes/2026-03-02-plan-critique.md`)
2. Identified and executed all zero-debate low-hanging fruit items
3. Created a continuation handoff for further work

The original chunks (1-8) were superseded. See:
- `notes/handoffs/2026-03-02-low-hanging-fruit.md` — what was actually done (all complete)
- `notes/handoffs/2026-03-02-continued-improvements.md` — what to do next

## Handoff Notes

**Session 45.** The review+spike approach was replaced with a "critique first, test first"
approach. Key insight: the 10-phase refactoring plan addresses structural aesthetics more
than real bugs. Only 3 real issues were found across all reviews: `!$expand` cycle detection
(fixed), `saResourceTypes` port bug (fixed), and `--format` silent fallback (fixed). The
remaining phases are deferred pending user decision on whether the codebase will see active
development (which would justify structural investment).
