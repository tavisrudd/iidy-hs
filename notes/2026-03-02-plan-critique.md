# Refactoring Plan: Critique & Alternatives

**Date**: 2026-03-02
**Status**: Draft for discussion
**References**: `notes/2026-03-02-refactoring-plan.md`, six review files

---

## Meta-Critique: The Reviews Themselves Have Blind Spots

Before critiquing the plan, the reviews it's based on deserve scrutiny.

All six reviews were **generated from code exploration, not from using the tool**. They apply
well-known design heuristics (Hickey: complecting; Ousterhout: depth; Minsky: illegal states;
etc.) to the source code. This produces valid structural observations but misses:

1. **No review found an actual bug.** The closest is Krishnamurthi's `!$expand` cycle detection
   gap — a real latent infinite loop. Everything else is "this pattern could *lead to* bugs."
   In a codebase with 958 tests and 37/37 snapshot matches, the delta between "could lead to
   bugs" and "has led to bugs" matters.

2. **The reviews don't account for the codebase's lifecycle stage.** This is a completed port.
   It's not under active feature development. The rate of new bugs introduced by *future changes*
   is near zero if nobody's changing the code. Refactoring to prevent future bugs only pays off
   if there *will be* future changes. What changes are actually anticipated?

3. **The reviews overlap heavily and reinforce each other's biases.** Hickey, Minsky, and Kmett
   all flag StackArgs and CfnContext — because those are the most visible patterns when reading
   source code. But visibility to a reader != importance to a user. The StackArgs 21-Maybe bag
   has worked correctly for 958 tests. The "illegal states" it permits (e.g., contradictory
   rollback settings) are caught by CloudFormation itself, which validates parameters.

---

## Critique 1: The Plan Solves the Wrong Problem First

The plan is ordered by "impact-to-effort ratio." But impact is measured by *structural elegance*,
not by *user-facing value* or *bug prevention*.

### Phases 1-2 (Enums + StackStatus): ~30 files, 5 commits

These replace `Text` with ADTs for OnFailure, Capability, OutputFormat, and StackStatus.
The justification: typos in these strings would be silent bugs.

**But has anyone ever typed `"BANANA"` as an OnFailure value?** The StackArgs YAML files are
written by developers using the iidy documentation. The Rust implementation has the same
stringly-typed representation and has been in production for years. If typos in these fields
were a real problem, they'd have been caught long ago.

The *only* Phase 1 enum with real user impact is **OutputFormat** (Phase 1.3), because the
`_ -> emitYaml` wildcard means a user typing `--format josn` silently gets YAML instead of
an error. That's a real UX bug. The other two enums fix theoretical problems in code paths
that are tested and working.

### Phase 6 (Testing): 0 files changed, 3 new test files

This is the most valuable phase and it's buried at position 6. Property tests can find *real
bugs today*. They're also zero-risk (additive, no code changes). They should run first because:

- If a property test fails, it found a real bug — justifying further refactoring
- If all properties hold, it *reduces* the justification for Phases 1-2 (the type safety
  the enums provide is already empirically verified by the properties)

### Recommendation

Reorder: **6 -> 1.3 -> 3 -> 10 -> everything else**.
Testing first. Then the one enum that affects users. Then error handling fixes that prevent
real safety issues. Then aesthetics if time permits.

---

## Critique 2: The Plan Ignores the Strongest Consensus Finding

Four of six reviewers flagged **error handling fragmentation** as a top issue:
- Hickey: "Five incompatible error handling strategies" (Severity: High)
- Ousterhout: "Tactical error handling"
- Minsky: "`Either Text` — callers can't pattern-match on failure mode"
- Kmett: "The monad stack that isn't"

The plan addresses this *peripherally*:
- Phase 3 converts TemplateLoader from `fail` to `Either` (1 module)
- Phase 10 narrows `SomeException` catches (12-15 modules)

But **neither phase introduces a unified error type.** After both phases, the codebase still
has `Either Text` everywhere. Callers still can't distinguish "stack not found" from "access
denied" from "template parse error."

A `data IidyError = ...` sum type replacing `Either Text` in the CFN layer would be higher
impact than Phases 1, 2, 4, 5, 7, 8, and 9 *combined*. It's the "Phase 0" the handoff's
self-critique asks about.

### Why It's Missing

The plan author likely excluded it because:
1. It touches every function signature in the CFN layer (~30+ functions)
2. It would break differential testing (error messages change)
3. It's the kind of change that's hard to do incrementally

But Phases 3 and 10 are already stepping stones toward this. If you're going to touch
TemplateLoader's error handling *and* narrow SomeException catches, you might as well
introduce the unified type at the same time.

---

## Critique 3: Phase 2.2 Scope Is Underestimated

The plan says Phase 2.2 (threading StackStatus through output types) touches "~12-15 files."

Actual count from codebase search:
- 6 output type fields to change in `Output/Types.hs`
- 9 construction sites across operation modules
- 2 renderer files (Interactive + JSON)
- 1 status categorization file
- Test builders for all 6 affected OutputData types
- Fixture constructors in property tests
- Any test that hardcodes a status string

The real number is **15-20 files** and the plan's "mechanical" assessment is optimistic.
Each status field change cascades: the operation module that constructs the record, the
renderer that displays it, the JSON converter that serializes it, the test builder that
creates test instances, and any test that pattern-matches on the status value.

Furthermore, `csiExecutionStatus :: Maybe Text` in `ChangeSetInfo` and `drDriftStatus :: Text`
in `DriftedResource` are *also* stringly-typed statuses that the plan doesn't mention. If
you're doing Phase 2 at all, these should be included.

---

## Critique 4: Phase 4 (CfnContext Separation) Has Low Payoff

Phase 4.1 removes `cfnCredentialSources` and `cfnOperation` from CfnContext. These fields
are used at exactly 1-2 call sites each. Removing them simplifies CfnContext from 7 fields
to 5 fields.

Phase 4.2 splits CfnContext into read/write variants. This touches ~16 files.

**The payoff is marginal.** The IORef "contamination" that Minsky flags is real but harmless
— no read-only operation has ever accidentally written to the token accumulator because the
code simply doesn't call the write functions. The type system improvement prevents a bug that
has never occurred and is unlikely to occur (the operations are stable, well-tested code).

Compare: the `!$expand` cycle detection gap (no phase in the plan) is a **real latent bug**
that a user could trigger today. Phase 4 prevents a hypothetical programmer error in stable
code; cycle detection prevents a real infinite loop in user-facing functionality.

### Recommendation

Drop Phase 4.2 entirely. Do Phase 4.1 only if someone is already working in those files.
Add `!$expand` cycle detection instead — it's ~10 lines of code (add a `Set Text` of active
expansion names, check before recursing).

---

## Critique 5: The Plan Makes the Codebase Bigger, Not Smaller

Muratori's review makes a point the plan doesn't address: 85 modules and 15k LOC for a YAML
preprocessor is a lot. The plan adds:

| Phase | New modules | New test files | New types |
|-------|------------:|---------------:|----------:|
| 1     |           0 |              0 |         3 |
| 2     |           0 |              0 |         1 |
| 5     |           0 |              0 |         2 |
| 6     |           0 |              3 |         0 |
| 7     |           1 |              0 |         0 |
| 9     |           0 |              0 |         1 |
| **Total** |     **1** |          **3** |     **7** |

The refactoring adds 7 new types, 1 new module, and 3 new test files. Nothing is removed.
`OdRawOutput` survives even after Phase 5 adds `OdRenderOutput` and `OdGetImportOutput`
(because param commands still use it).

A refactoring plan that only adds and never subtracts is a net complexity increase, not a
simplification. Each new type is a new thing to keep in sync, import, test, and document.

### What Could Be *Removed* Instead?

- **Phase 5 should delete `OdRawOutput`**, not keep it alongside new variants. Move param
  command output to `OdParamOutput !ParamOutput` and remove the escape hatch entirely. The
  whole point of Phase 5 is to eliminate the unstructured variant — leaving it defeats the
  purpose.
- **Phase 7.1** extracts a new `StackArgs.Validation` module. But `getStrMapValidated` and
  `resolveEnvMaps` are only called from `StackArgsLoader`. Extracting them to a separate
  module adds a new file, a new module header, new imports, new exports — for functions
  with exactly one caller. The "exported for testing" comment is a code smell, but the fix
  is making the StackArgsLoader tests test through the public API, not extracting internals
  to a new module so they have a "natural" public API. The extracted module's only consumer
  is tests.

---

## Critique 6: `saResourceTypes` Is a Real Bug, Not Mentioned

The explore agent found that `saResourceTypes :: Maybe [Text]` is parsed from YAML in
`StackArgsLoader` but **never consumed by `RequestBuilder`**. The field is silently dropped.

This is a functional bug — if a user specifies `resourceTypes` in their stack-args YAML,
iidy silently ignores it. The Rust implementation may or may not have the same issue (this
needs verification), but either way it's a real gap that no phase in the plan addresses.

This is worth more than Phases 4, 5, 8, and 9 combined — it's an actual bug vs. structural
aesthetics.

---

## Critique 7: Phase 10 (SomeException) Is Higher Risk Than Stated

The plan says Phase 10 touches "~12-15 files" and calls the risk "Medium."

Actual `try @SomeException` count: **19 calls across 10 files.** The plan's file count is
approximately right, but the risk assessment undersells the danger.

Narrowing `try @SomeException` to specific exception types changes *observable behavior*:
exceptions that were previously caught and handled now propagate to the top level. The plan
says "this is correct behavior" — and it is, in principle — but it can change failure modes
that users have adapted to.

Example: `Iidy/Params/Review.hs` has 3 `try @SomeException` calls. If these catch
`Amazonka.Error` specifically, what happens when the underlying HTTP client throws an
`HttpException` that isn't an `Amazonka.Error`? Currently it's caught and handled. After
narrowing, it propagates as an unhandled exception with a stack trace — worse UX than the
current behavior.

### Recommendation

Phase 10 should be **audited per-site**, not done as a mechanical replacement. Each `try
@SomeException` needs analysis of what exception types actually occur at that call site.
Several may be intentionally broad (the NTP client is explicitly noted as one). Others may
need `catches` with multiple exception handlers rather than a single narrowed `try`.

---

## Alternative Approaches

### Alternative A: "Fix Real Bugs Only" (~3 commits)

Only do work that fixes actual or latent bugs:

| Item                                          | Type          | Effort |
|-----------------------------------------------|---------------|--------|
| `!$expand` cycle detection                    | Latent bug    | Small  |
| OutputFormat enum (Phase 1.3)                 | UX bug        | Small  |
| `saResourceTypes` investigation               | Functional bug| Small  |
| JMESPath subset documentation (Phase 6.2)     | User confusion| Small  |

**Total**: 4 items, ~4 files touched, 3-4 commits. Everything else is deferred.

**Pros**: Minimal risk, maximum bug-fix-per-commit ratio, done in one session.
**Cons**: Leaves all structural issues untouched. Doesn't improve maintainability.

### Alternative B: "Testing First, Then Decide" (~5 commits)

1. Phase 6 (all three sub-phases) — property tests, JMESPath docs, error content tests
2. `!$expand` cycle detection
3. OutputFormat enum (Phase 1.3)

After step 1, evaluate: **did any property test fail?** If yes, fix the bugs and use the
findings to prioritize further refactoring. If all pass, the codebase is empirically correct
and the remaining refactoring phases are aesthetic.

**Pros**: Data-driven. Testing finds real issues; absence of test failures reduces urgency
of structural changes. Low risk (mostly additive).
**Cons**: Doesn't address any structural issues. May feel unsatisfying after generating 6
detailed reviews.

### Alternative C: "The Big Three" (~8 commits)

Do the three highest-consensus, highest-impact changes:

1. **Unified IidyError type** replacing `Either Text` in the CFN layer (consensus: 4 reviewers)
2. **Phase 2.1** — StackStatus sum type at the boundary (consensus: 3 reviewers)
3. **Phase 6.1** — Property tests (unique but highest value)

Skip everything else. These three address the most-cited issues and produce the most
structural improvement per commit.

**Pros**: Addresses the consensus findings. Meaningful structural improvement.
**Cons**: IidyError type is a significant change (~30+ function signatures). No existing
phase in the plan covers it.

### Alternative D: "User-Facing Only" (~4 commits)

Only do work that a *user* of iidy would notice:

1. OutputFormat enum with CLI validation (Phase 1.3) — no more silent YAML on `--format josn`
2. JMESPath subset documentation + better parser errors (Phase 6.2) — no more "parse error"
   on `length(@)`
3. `!$expand` cycle detection — no more infinite loop on circular custom resources
4. Error content tests in `cabal test` (Phase 6.3) — CI catches error regressions

**Pros**: Everything done has user-visible benefit. Zero risk of internal regressions from
type changes. Done in 1-2 sessions.
**Cons**: Leaves all internal structural issues untouched.

### Alternative E: "Graduate from Port" (~15+ commits, multi-session)

Accept that the codebase is no longer "the Rust port" and make it properly Haskell:

1. `ReaderT CfnEnv IO` monad stack (addresses Hickey #1, Ousterhout #2, Minsky #4, Kmett #3)
2. `ExceptT IidyError` for uniform error handling (addresses the 4-reviewer consensus)
3. Per-operation argument types (addresses Hickey #2, Ousterhout #5, Minsky #1)
4. Property tests (Phase 6.1)

This is what Kmett's review actually recommends: stop being "Haskell as a better Java" and
use the language's abstractions. The exclusions list (no MTL, no ExceptT, no typeclasses)
made sense during the port. The port is done.

**Pros**: Transforms the codebase into idiomatic Haskell. Addresses root causes, not symptoms.
Single structural change (ReaderT + ExceptT) replaces 5-6 incremental phases.
**Cons**: Highest risk. Breaks differential testing assumptions. Touches nearly every module.
Multi-session effort. May not be worth it if the tool is "done."

---

## Recommendation

**Alternative B** (Testing First, Then Decide) with the bug fixes from **Alternative A**
mixed in.

Concretely:

1. Phase 6.1 — Property tests for preprocessing tags
2. Phase 6.2 — JMESPath subset documentation + parser errors
3. Phase 6.3 — Error content tests in `cabal test`
4. OutputFormat enum (Phase 1.3) — the one enum that affects users
5. `!$expand` cycle detection — the one latent bug
6. Investigate `saResourceTypes` — the one possible functional bug

Then stop and evaluate. If property tests found bugs, the type safety improvements (Phases
1-2) are justified. If they didn't, the codebase is empirically correct and the remaining
phases are nice-to-have, not need-to-have.

The risk calculus: 17 commits touching 40 files in a stable, tested codebase. Every commit
is a chance to introduce a regression. The testing phases *reduce* future regression risk
(more tests = better safety net). The refactoring phases *introduce* short-term regression
risk for long-term structural improvement. Do the risk-reducing work first.

---

## Open Questions

1. **What changes are actually anticipated for this codebase?** If the answer is "none, it's
   a complete port," most refactoring has zero payoff. If the answer is "we'll add new
   preprocessing tags / new output modes / new import sources," the structural improvements
   start to pay off.

2. **Does Rust also silently drop `saResourceTypes`?** If yes, it's a shared design decision
   (the field exists in the YAML schema but isn't used by any operation). If no, it's a port
   bug.

3. **Has anyone ever hit the `!$expand` infinite loop?** If the custom resource system isn't
   heavily used, the cycle detection gap is theoretical.

4. **Is JSON output mode (`--output json`) actually used?** If not, `OdRawOutput` and the
   entire Phase 5 are irrelevant.
