# Process Trust Guide: iidy-hs

**Date**: 2026-03-01
**Context**: Written immediately after completing a due diligence review and watching all addressable fixes land in 30 minutes.
**Audience**: Anyone inheriting, auditing, or maintaining this codebase who wants to know how to trust it and keep trusting it without reading every line.

---

## 1. The Process That Produced This Code

This is a 17,200 LOC Haskell application with 7,300 LOC of tests, built in 8
days (Feb 21 - Mar 1, 2026) across 183 commits by Claude (Anthropic's AI)
running under human direction. The human wrote zero lines of Haskell. The human
wrote the rules, directed priorities, performed live AWS testing, and sent
real-time course corrections via a message inbox (`.msgs/`). The AI wrote all
the code, all the tests, all the documentation, and all the review artifacts.

### What worked

**The constitution model.** The `CLAUDE.md` file (90 lines) imposed hard
constraints that the AI followed consistently across 40+ sessions:
- `-Wall -Wcompat` clean, zero warnings -- enforced at every commit
- No partial functions (`head`, `tail`, `fromJust`, `undefined`) -- zero
  occurrences in the final codebase
- No `TODO` or `FIXME` comments -- zero occurrences in source
- Green commits only -- all tests pass at every commit point
- Explicit type signatures on all top-level bindings

These rules were not aspirational. They were verified mechanically (the
compiler enforces warnings; grep confirms absence of banned patterns) and the
AI treated them as non-negotiable constraints.

**Phased execution with gates.** The work was organized into 16 phases with
explicit entry/exit criteria. Each phase had a research sub-document in
`notes/phases/` committed before implementation began. Phase gates required all
tests passing, snapshot parity checks, and documentation updates before
advancement.

**Oracle testing.** The Rust reference implementation provided behavioral
verification. Two snapshot comparison scripts (`scripts/snapshot-compare.sh`,
`scripts/error-snapshot-compare.sh`) compared Haskell output against 37 render
fixtures and 49 error fixtures from the Rust test suite. All 86 pass.

**Review loops.** Three rounds of AI code review (the reviewer was the same AI
system, but in a fresh session with a review-specific prompt). The third loop
ran 14 rounds on CFN operations/polling alone, raising the score from 72 to 90.
Review findings and fixes are documented in `notes/reviews/2026-*-review--cfn-operations-polling--round-*.md` (14
files) and the due diligence report at
`notes/reviews/2026-03-01-review--general-due-diligence.md`.

**Live testing as a backstop.** The human ran the tool against real AWS
infrastructure (CloudFormation stacks, SSM parameters, S3, STS). This caught
three critical bugs the snapshots missed: `--profile` silently ignored,
`--assume-role-arn` never executed, and missing region silently defaulting to
us-east-1. These were fixed in Phase 15.

### What the gaps were

**Fixture coverage was not audited upfront.** The 86 snapshot fixtures covered
rendering and error display thoroughly but did not cover the AWS authentication
chain, changeset execution paths, or polling loop behavior. Bugs in those areas
were only caught by live testing.

**The workplan had gaps.** The AI declared the port complete after Phase 8, and
it was right -- it had completed everything in the plan. The plan itself was
missing output pipeline wiring, CLI divergences, and error color display. The
human had to reopen the workplan and add Phases 9-16.

**AI self-review has systematic blind spots.** The same system that wrote the
JMESPath parser reviewed the JMESPath parser. If there is a semantic
misunderstanding in the implementation that matches a misunderstanding in the
AI's training data, no amount of self-review will find it.

---

## 2. The Process Trust Model

The thesis, drawn from the companion essay ("Review the Process to Trust the
Code"): you do not need to read every line of a codebase if you can evaluate
whether the process that produced it was disciplined. This is the same skill
experienced technical leaders use when reviewing PRs from human engineers --
evaluating planning quality, case analysis, risk identification, and
verification strategy rather than auditing every line of implementation.

### How this applies to iidy-hs

The process artifacts for this project are extensive and committed to the
repository. They are the primary evidence for trust:

| Artifact                    | Location                                                                         | What it tells you                                                |
|:----------------------------|:---------------------------------------------------------------------------------|:-----------------------------------------------------------------|
| Coding constitution         | `CLAUDE.md`                                                                      | What rules governed every AI session                             |
| Phased workplan             | `WORKPLAN.md`                                                                    | How the work was sequenced and gated                             |
| Phase research docs         | `notes/phases/`                                                                  | Whether research preceded implementation                         |
| Session handoffs            | `notes/sessions/`, `notes/handoffs/`                                             | How context was carried between sessions                         |
| Review round findings       | `notes/reviews/`                                                                 | What was found and fixed in each review round                    |
| Due diligence report        | `notes/reviews/2026-03-01-review--general-due-diligence.md`                      | Independent assessment with scorecard and risk register          |
| Architecture decision recs  | `docs/dev/adr/`                                                                  | Why major design choices were made, with trade-offs acknowledged |
| Known divergences           | `DIVERGENCES.md`                                                                 | What intentionally differs from the reference and why            |
| Progress log                | `progress.log`                                                                   | Timestamped chronological record of work completed               |
| Commit history              | `git log`                                                                        | 183 small, green, descriptive commits                            |
| Risk review                 | `notes/reviews/2026-02-21-review--initial-workplan-risks-persona:mcconnell.md`   | Pre-implementation risk analysis using McConnell estimation      |
| Agent resilience analysis   | `notes/workplan-agent-resilience.md`                                             | 12 cataloged stuck states with mitigations                       |

**What these artifacts can tell you:**
- Whether the work was planned before implemented (research docs predate code)
- Whether quality gates were enforced (commit history shows green-only commits)
- Whether risks were identified honestly (risk review caught estimation bias)
- Whether course corrections happened (workplan was reopened, phases added)
- Whether known limitations are documented (DIVERGENCES.md, security model)

**What these artifacts cannot tell you:**
- Whether the AI understood the domain deeply enough (it can produce
  disciplined-looking artifacts with shallow understanding)
- Whether the oracle (Rust reference) was itself correct
- Whether untested paths work correctly
- Whether the custom parsers (JMESPath, Handlebars, JSON Schema) conform to
  their respective specifications in edge cases not exercised by iidy's usage

---

## 3. Monitoring the Process (Ongoing)

These are the concrete signals to watch. None of them require reading source
code.

### CI as a trust floor

The GitHub Actions pipeline (`.github/workflows/ci.yml`) runs on every push to
main:
- `cabal build all -Wall -Wcompat` -- zero warnings required
- `cabal test all` -- all 851 tests must pass

If CI is green, the codebase meets its minimum quality bar. If CI ever goes
red, something has degraded and should be treated as a blocking issue.

**Command to verify locally:**
```bash
nix develop --command bash -c "cabal build all -Wall -Wcompat 2>&1 | tail -5 && cabal test all --test-show-details=direct"
```

### Snapshot parity as behavioral verification

The snapshot comparison scripts verify that iidy-hs produces byte-identical
output to the Rust reference implementation across all covered fixtures.

**Commands:**
```bash
# Render output parity (37 fixtures)
scripts/snapshot-compare.sh

# Error display parity (49 fixtures)
scripts/error-snapshot-compare.sh
```

If these pass, the rendering and error display subsystems match the reference.
If a code change causes a fixture to fail, the change has altered user-visible
behavior and must be examined.

**Limitation:** These only cover paths exercised by the fixtures. AWS
operations, polling, authentication, and changeset execution are not covered by
snapshots.

### Property tests as crash resistance evidence

Six QuickCheck properties in `test/Test/PropertyTest.hs` test that the custom
parsers (JMESPath, Handlebars, YAML emitter) do not crash on arbitrary input.
These run as part of `cabal test` and provide confidence that the parsers are
robust against malformed input.

**What they test:** Crash resistance (no exceptions on arbitrary input).
**What they do not test:** Semantic correctness (that the parse result is
correct for valid input).

### Commit hygiene

Review the commit history periodically:
```bash
git log --oneline -20
```

Healthy signals:
- Small, focused commits (one concern per commit)
- Descriptive messages that explain what and why
- No "fix tests" commits (tests should not have broken in the first place)
- No "revert" chains (indicates thrashing)

Degradation signals:
- Large commits touching many unrelated files
- Vague messages ("updates", "fixes", "WIP")
- Commits that disable tests or add `-Wno-*` flags
- Long gaps between commits followed by large dumps

### The demo command as end-to-end smoke test

`iidy demo` runs a built-in demonstration that exercises the YAML preprocessor,
custom resource expansion, Handlebars templates, JMESPath expressions, imports,
and the output pipeline. It does not require AWS credentials.

```bash
nix develop --command bash -c "cabal run iidy-hs -- demo"
```

If demo runs without error, the core preprocessing pipeline is functional. This
is not a substitute for the test suite but provides a fast human-visible
integration check.

### What to watch for that indicates process degradation

- **Warning count rising from zero.** Any non-zero warning count means the
  `-Wall -Wcompat` discipline has lapsed. This is the canary.
- **Test count decreasing.** Tests being deleted or commented out without
  corresponding feature removal means quality is being traded for velocity.
- **Snapshot comparison failures being ignored.** If fixtures start failing and
  the response is to update the fixture rather than investigate the behavioral
  change, parity with the reference is being abandoned.
- **CLAUDE.md rules being relaxed.** If rules like "no partial functions" or
  "green commits only" are removed or softened, the quality floor is dropping.
- **Documentation going stale.** If code changes land without corresponding
  updates to DIVERGENCES.md, ADRs, or developer docs, the documentation will
  drift from reality and lose its value as a trust artifact.
- **Large commits without review artifacts.** If significant changes land
  without corresponding review notes or handoff documents, the process
  discipline has been abandoned.

---

## 4. Modifying the Process

### The CLAUDE.md file as the constitution

`CLAUDE.md` is the single most important file in the repository for process
trust. It defines the rules that govern every AI session. When the AI opens a
session, it reads this file first and treats its contents as binding
constraints.

To change how the AI works on this codebase, change CLAUDE.md. To add a new
quality requirement, add it there. To relax a constraint, remove it there --
but understand that you are lowering the quality floor.

**Key rules to preserve:**
- `-Wall -Wcompat` clean, zero warnings
- No partial functions
- Green commits only
- 100% tests pass on every commit

**Rules you might want to add:**
- Minimum test coverage for new modules (e.g., "every new module must have a
  corresponding test module")
- Required review artifact for changes above N lines
- Mandatory snapshot comparison before merge

### How to add new quality gates

1. Define the gate in CLAUDE.md (what must be true before the change is
   committed).
2. Add a verification command that can be run mechanically (a script, a test,
   a grep pattern).
3. Add that command to CI (`.github/workflows/ci.yml`).
4. Optionally add it to the end-of-session gate checklist in CLAUDE.md.

Example: adding snapshot comparison to CI:
```yaml
- name: Snapshot comparison
  run: |
    scripts/snapshot-compare.sh
    scripts/error-snapshot-compare.sh
```

This requires the Rust snapshots to be available in CI, which may require
checking them into the repo or pulling from the Rust repository.

### How to extend test coverage for new features

The test infrastructure is well-structured for extension:

1. **Create a new test module** in `test/Test/NewFeatureTest.hs`.
2. **Use test data builders** from `test/Test/Shared.hs` for OutputData types.
3. **Register the module** in `test/Main.hs` by importing and adding to the
   test tree.
4. **For AWS operations**, use the dependency injection pattern: pass mock IO
   actions instead of real AWS contexts (see `pollForCompletionWith` in
   `src/Iidy/Cfn/StackOperations.hs` for the pattern).
5. **For rendering**, emit OutputData values through a mock dispatcher and
   verify the output (see `test/Test/IntegrationTest.hs`).

### When human review IS needed

Process trust has limits. Human review is essential for:

- **Credential handling changes.** Any modification to `src/Iidy/Aws/Config.hs`
  (AWS environment setup), `src/Iidy/Aws/Sts.hs` (STS assume-role), or the
  `--profile`/`--assume-role-arn` code paths. These directly affect which AWS
  credentials are used and an error here means operating on the wrong account.

- **New AWS API integration.** Adding calls to new AWS services or endpoints.
  The AI's understanding of AWS API semantics is based on documentation, not
  operational experience. Behavioral assumptions (eventual consistency,
  throttling, error codes) need human validation against real AWS.

- **Security boundary changes.** Any modification to the import security model
  (`src/Iidy/Yaml/Imports/Types.hs`), remote template restrictions, or the
  `mask-secrets` functionality.

- **Custom parser changes.** Modifications to the JMESPath
  (`src/Iidy/Yaml/JMESPath.hs`), Handlebars
  (`src/Iidy/Yaml/Handlebars/Engine.hs`), or JSON Schema
  (`src/Iidy/Yaml/CustomResources/JsonSchema.hs`) implementations. These are
  custom-built from spec and are the highest-risk subsystems for subtle bugs.

- **Dependency upgrades.** Particularly `amazonka` version bumps, which can
  change API types and behavior in non-obvious ways.

### How the review loop works as an automated quality ratchet

The review loop (`t-review-loop` or equivalent prompt) works as follows:

1. A fresh AI session is started with a review-specific prompt targeting a
   subsystem (e.g., "Review the CFN operations and polling code").
2. The reviewer examines the code and produces findings with severity ratings.
3. A fix session addresses the findings.
4. The reviewer re-examines and scores.
5. Steps 3-4 repeat until the score stabilizes or reaches the target.

Each round's findings are documented in `notes/` (e.g.,
`notes/reviews/2026-*-review--cfn-operations-polling--round-*.md`). This
creates a ratchet: each round catches issues the previous round missed, and the
score can only go up because fixes do not introduce regressions (CI enforces
this).

**Limitations of the ratchet:**
- The reviewer shares the same training data and systematic biases as the
  author. Some bug classes will never be found this way.
- The score reflects the reviewer's assessment, not ground truth. A 90/100 from
  an AI reviewer is not equivalent to a 90/100 from a domain expert.
- The ratchet only works on code that exists and is tested. It cannot find
  missing features or untested paths.

---

## 5. What Cannot Be Trusted Without Human Review

Being honest about the limits is the most important part of this guide.

### Custom parser edge cases beyond fuzz test coverage

The JMESPath, Handlebars, and JSON Schema implementations are custom-built
(combined ~1,290 LOC). They have unit tests covering iidy's usage patterns and
fuzz properties testing crash resistance. They do not have:
- Compliance test suites (JMESPath has an official compliance suite that has
  not been run against this implementation)
- Semantic fuzzing (testing that parse results are correct, not just that they
  do not crash)
- Adversarial input testing beyond random strings

These parsers work for the inputs iidy currently generates. They may fail on
unusual but valid inputs.

### AWS API behavioral assumptions

The codebase makes assumptions about AWS API behavior that can only be verified
by live testing:
- CloudFormation event ordering and pagination
- Stack status transition sequences
- Changeset execution timing
- S3 eventual consistency behavior
- STS token refresh timing
- SSM parameter store pagination

These are listed in `DIVERGENCES.md` under "Live AWS Operations (Untestable
Offline)." Mock-based tests verify the code's logic given certain API responses,
but they cannot verify that the API actually produces those responses.

### Credential handling and security boundaries

The import security model (`docs/SECURITY.md`) is documented and the code is
clean, but:
- `setEnv "AWS_PROFILE"` modifies the global process environment, which is not
  thread-safe in Haskell. Acceptable for a CLI tool but dangerous if the code
  is ever used as a library.
- The NTP client makes unencrypted UDP calls to `pool.ntp.org`.
- `regex-posix` in JSON Schema validation is vulnerable to ReDoS on adversarial
  patterns. Low risk since patterns come from template authors (trusted), but
  worth noting if the trust boundary ever changes.
- No input length limits on YAML files, import chains, or template strings.

### Anything the oracle did not cover

The Rust reference implementation was the primary verification mechanism. Any
behavior that the Rust implementation does not exercise in its test suite is
unverified in iidy-hs. Specifically:
- The Rust test suite does not have integration tests for the full CLI pipeline
  (parse args -> load YAML -> preprocess -> emit). Neither does iidy-hs.
- The Rust test suite does not cover AWS authentication chain behavior in its
  snapshots. The three critical auth bugs in iidy-hs were invisible to snapshot
  comparison.

### The unknown unknowns

These are the hardest to enumerate, which is the point:
- The AI's understanding of CloudFormation's behavior comes from documentation
  and training data, not operational experience. There may be undocumented AWS
  behaviors that the Rust implementation handles correctly (because its author
  discovered them through production use) that the Haskell port does not
  replicate because they are not in the code, only in the author's mental
  model.
- The AI reviewing its own code shares the same systematic biases. A
  misunderstanding that pervades the implementation will also pervade the
  review.
- Concurrency bugs, resource leaks, and race conditions are extremely difficult
  for any reviewer (human or AI) to find by code reading. The polling loops,
  spinner threads, and NTP client all involve concurrent IO that has not been
  stress-tested.

---

## 6. The 30-Minute Fix Cycle as Evidence

The due diligence review identified 10 risks and 10 recommendations. Within
30 minutes, 7 of 10 recommendations were fully addressed, 1 partially
addressed, and 4 of 10 risks were fully resolved. Six new fuzz test properties
were added. Zero warnings were introduced.

### What this tells us about the AI+human maintenance model

**Velocity is real.** The AI has full codebase context (17,200 LOC fits in a
single context window) and can make coordinated changes across multiple files
simultaneously. A human developer would need hours or days to build equivalent
context for changes that span dependency management (`lens` to `microlens`),
build configuration (multi-platform Nix flake), CI setup (new GitHub Actions
pipeline), and code refactoring (12 uses of `T.head`/`T.last` replaced across
3 files). The AI did all of this in 30 minutes with zero regressions.

**Responsiveness to quality feedback is immediate.** The fix cycle was not
"acknowledge the issues and schedule for later." Every addressable finding was
fixed in the same session, verified against the test suite, and committed. This
is a property of the AI+human model that is difficult to replicate with human
teams, where fix cycles involve context switches, scheduling, and prioritization
debates.

**The fixes were substantive.** Replacing `lens` with `microlens` required
auditing all import sites. Eliminating the `yaml` dependency required finding
and rewriting the one call site using `Data.Yaml`. The
`extractServiceErrorMessage` rewrite required understanding amazonka's
`ServiceError` internals. The CI pipeline required understanding GitHub Actions,
cabal caching, and GHC version pinning. These were not cosmetic changes.

### The limits

**These were "known issue, clear fix" problems.** Every fix in the cycle had a
well-defined problem statement from the review and a straightforward
remediation. None required deep debugging, architectural redesign, novel domain
knowledge, or extended investigation. The 30-minute speed is impressive but the
difficulty level was low-to-medium.

**The same system wrote and fixed the code.** Certain classes of systematic
error (e.g., a misunderstanding of how JMESPath multi-select hash should work)
would not be caught by this process because the same misunderstanding would
persist in both the implementation and the fix.

**Speed on easy problems does not predict speed on hard problems.** A subtle
race condition in the polling loop, a misunderstanding of CloudFormation's
eventual consistency model, or an edge case in the Handlebars template engine
would take far longer to diagnose and might require live AWS testing, spec
consultation, or human domain expertise. The 30-minute cycle is evidence of
maintenance capability, not omniscience.

---

## 7. Recommended Trust Cadence

### Per-commit (automated, non-negotiable)

- CI passes: `cabal build all -Wall -Wcompat` produces zero warnings
- CI passes: `cabal test all` -- all tests pass
- These are already configured in `.github/workflows/ci.yml`

### Per-feature (before merging significant changes)

- Run snapshot comparison against Rust reference:
  ```bash
  scripts/snapshot-compare.sh
  scripts/error-snapshot-compare.sh
  ```
- Run the demo command to verify core pipeline:
  ```bash
  cabal run iidy-hs -- demo
  ```
- Verify no new partial functions introduced:
  ```bash
  grep -rn 'fromJust\|Data\.List\.head\|Data\.List\.tail\|\bundefined\b' src/
  ```
- Verify no new TODOs or stubs:
  ```bash
  grep -rn 'TODO\|FIXME\|HACK\|XXX\|error "' src/
  ```

### Monthly (automated via review loop)

- Re-run the due diligence review prompt against the current codebase. Compare
  the scorecard against the baseline (current: low A-). Any dimension that has
  dropped requires investigation.
- Review the commit log for the month. Check for degradation signals (large
  commits, vague messages, test deletions).
- Verify test count has not decreased (current: 851).

### Quarterly (requires human judgment)

- Human review of security-critical paths:
  - `src/Iidy/Aws/Config.hs` -- credential handling
  - `src/Iidy/Aws/Sts.hs` -- STS assume-role
  - `src/Iidy/Yaml/Imports/Types.hs` -- import security model
  - `docs/SECURITY.md` -- security documentation currency
- Review DIVERGENCES.md for any new entries that might indicate behavioral drift
- Live AWS testing of the commands you actually use in production

### On dependency update

- Rebuild and retest: `cabal build all -Wall -Wcompat && cabal test all`
- Check for new deprecation warnings (even if the total stays at zero, new
  warnings from updated deps may appear)
- For `amazonka` updates specifically: verify that `OverloadedRecordDot` field
  access still works (amazonka uses `DuplicateRecordFields` and field access
  patterns can break between major versions)
- Run snapshot comparison to verify output has not changed
- Run demo command

### On GHC version update

- Full rebuild from clean
- Verify zero warnings (new GHC versions may introduce new warning categories)
- Run full test suite
- Check for any `-Wcompat` warnings that have become real warnings in the new
  version

---

## Summary

Trust in this codebase is built on layers:

1. **Compiler enforcement** -- GHC with `-Wall -Wcompat` catches type errors,
   missing cases, unused imports, and compatibility issues at compile time.
2. **Rule enforcement** -- CLAUDE.md bans partial functions, stubs, and
   uncommitted debt. Grep verification confirms compliance.
3. **Test enforcement** -- 851 tests run on every commit via CI, covering unit
   tests, property tests, fixture comparisons, and integration tests.
4. **Behavioral verification** -- 86 snapshot comparisons against the Rust
   reference implementation verify output parity on covered paths.
5. **Review enforcement** -- Three review loops with documented findings and
   fixes, raising quality from 72 to 90.
6. **Process documentation** -- Committed workplans, handoffs, ADRs, risk
   reviews, and session logs make the development process auditable.

The gaps are in layers that do not exist:
- No compliance test suites for custom parsers
- No live AWS integration tests in CI
- No human code review of implementation details
- No production deployment history
- No stress testing or performance benchmarks

To trust this codebase, verify the layers that exist are intact (CI green, tests
passing, snapshots matching, no banned patterns). To increase trust, add the
missing layers. To maintain trust over time, follow the cadence above and watch
for degradation signals.

The process that produced this code was disciplined. The artifacts prove it.
The process is not perfect -- the gaps listed above are real. But it is
auditable, verifiable, and reproducible, which is more than most codebases
can claim regardless of whether a human or an AI wrote them.
