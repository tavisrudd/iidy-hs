# Machine Verification of Requirements: Analysis and Recommendations

**Project:** iidy-hs (Haskell port of iidy Rust CloudFormation tool)
**Date:** 2026-03-05
**Scope:** How to structure requirements documents for machine-verifiable implementations

---

## 1. Current State Assessment

### 1.1 Requirements Structure

The iidy-hs requirements are spread across 13 documents in `docs/requirements/`, organized by subsystem:

| Document                     | Domain                                   | Style                |
|------------------------------|------------------------------------------|----------------------|
| `00-overview.md`             | Product overview, personas, key concepts | Narrative            |
| `01-cli-interface.md`        | CLI commands, flags, parsing             | User stories + AC    |
| `02-yaml-preprocessing.md`  | Preprocessing tags, scoping, pipeline    | User stories + AC    |
| `03-import-system.md`        | Import types, loaders, resolution        | User stories + AC    |
| `04-custom-resources.md`     | Custom resource expansion, `$params`     | User stories + AC    |
| `05-cfn-operations.md`       | 14 CloudFormation operations             | User stories + AC    |
| `06-output-system.md`        | OutputData types, renderers              | User stories + AC    |
| `07-error-handling.md`       | Error codes, display format              | User stories + AC    |
| `08-aws-integration.md`      | Credential resolution, S3 upload         | User stories + AC    |
| `09-ssm-params.md`           | SSM parameter CRUD                       | User stories + AC    |
| `10-template-approval.md`    | Approval workflows                       | User stories + AC    |
| `11-utilities.md`            | render, demo, explain, convert           | User stories + AC    |
| `12-cross-cutting.md`        | SIGINT, NTP, color, YAML 1.1 compat     | User stories + AC    |

Each requirement follows a consistent template:

```
### US-XX-NNN: Title
**As a** <persona>, **I want to** <action>, **so that** <benefit>.
**Acceptance Criteria:** (bullet list)
**Logic Flow:** (pseudocode or ASCII flow)
**Edge Cases:** (bullet list)
**Error Scenarios:** (ERR_XXXX codes)
**Complexity Notes:** (implementation guidance)
```

### 1.2 What Makes Them Easy to Verify

**Structured error codes.** Every error condition has a unique `ERR_XXXX` code. This is directly testable: you can enumerate all codes and verify each has a test triggering it. The `ErrorIdTest.hs` and `ErrorFixtureTest.hs` files exploit this structure.

**Explicit edge cases.** Each user story lists edge cases as separate bullets, many of which map directly to unit tests. For example, US-02-003 explicitly states "zero is truthy" and "a string containing 'false' is truthy" -- these are immediately translatable to test assertions.

**Pseudocode logic flows.** The `Logic Flow` sections in `05-cfn-operations.md` use an arrow-chain notation that closely mirrors the actual implementation sequence. These are effectively informal state machine descriptions.

**Decision tables.** US-05-005 (create-or-update) includes an explicit `(exists, useChangeset)` decision table with 4 cells. This is rare but extremely valuable for verification.

**Behavioral oracle.** The Rust implementation is declared the behavioral oracle in `00-overview.md`: "identical stdout/stderr content, exit codes, error messages, and ANSI formatting for all inputs."

### 1.3 What Makes Them Hard to Verify

**Natural language ambiguity.** Acceptance criteria are prose bullets like "Variables defined in `$defs` are available to the body and to subsequent `$defs` entries and `$imports` location strings." This is precise enough for a human but not machine-parseable. What constitutes "available"? What does "subsequent" mean if keys are reordered?

**Implicit coverage requirements.** There is no traceability matrix linking each AC bullet to a test. A test suite can pass all tests while still missing a specific edge case bullet from a requirement.

**Mixed abstraction levels.** The same document mixes high-level behavioral requirements ("loading the argsfile succeeds before any AWS API call") with implementation-level details ("stack ID is extracted from the CreateStack response; if absent, falls back to the stack name"). The former is a property; the latter is a code path.

**Incomplete formalization of branching logic.** While US-05-005 has a decision table, most complex operations (e.g., the error display pipeline with its codes, ANSI color assignments, and conditional caret rendering) are described narratively. The branching logic is implicit in the prose.

**No input/output examples in requirements.** The requirements describe what should happen but rarely show a concrete input document and its expected output. The actual test fixtures exist in `test/fixtures/` but are disconnected from the requirements text.

### 1.4 The Role of PLT Redex

The PLT Redex specification in `spec/` serves three purposes:

1. **Executable ground truth for preprocessing semantics.** The `define-judgment-form` rules in `eval.rkt` are the canonical definition of what each preprocessing tag does. Unlike prose acceptance criteria, these are unambiguous and machine-checkable.

2. **Conformance bridge via snapshots.** The `spec/snapshot.json` file captures the spec's behavior on key drift-point areas (truthiness, merge ordering, path resolution, escape semantics). Haskell tests in `SpecConformanceTest.hs` verify agreement without requiring Racket at test time.

3. **Property-based specification.** The `redex-check` properties in `spec/tests/properties.rkt` express algebraic laws (idempotency, commutativity, identity elements) that hold over randomly generated terms.

**Limitations:** The spec covers only the preprocessing language. CloudFormation operations, CLI parsing, output formatting, error display, and AWS integration have no formal specification. The sub-language composition gap (Handlebars/JMESPath cannot be called from the eval judgment) means the most complex interactions are tested but not formally specified.

---

## 2. Reformulation Strategies for Machine Verification

### 2.1 Property-Based Specifications

Many requirements express algebraic properties that are natural fits for QuickCheck/Hedgehog.

**Already captured (in `PreprocessingPropertyTest.hs` and `PropertyTest.hs`):**
- OValue round-trip through JSON
- Merge identity and associativity
- Resolver preserves plain values

**Extractable from requirements but not yet tested as properties:**

**a) Truthiness trichotomy (from US-02-003):**
The requirement states three truthiness variants with a table. This is a perfect property:

```haskell
-- Property: iidy truthiness disagrees with Handlebars truthiness
-- only on (ONumber 0)
prop_truthiness_divergence :: OValue -> Property
prop_truthiness_divergence v =
  oIsTruthy v /= hbsIsTruthy v ==> v === ONumber 0
```

**b) $defs let* ordering (from US-02-001):**
"Each definition may reference earlier definitions in the same `$defs` block" implies:

```haskell
-- Property: reordering $defs entries may change the result
-- (i.e., order is semantically significant)
prop_defs_order_matters :: [(Text, OValue)] -> Property
prop_defs_order_matters defs =
  length defs >= 2 ==>
    resolveDefs defs /= resolveDefs (reverse defs)
```

**c) Merge key-order preservation (from US-02-004):**

```haskell
-- Property: keys(merge [a, b]) starts with keys(a) in order,
-- followed by keys in b not in a, in order
prop_merge_key_order :: OValue -> OValue -> Property
prop_merge_key_order (OObject a) (OObject b) =
  let merged = mergeOObjects [OObject a, OObject b]
      mergedKeys = map fst (oObjectPairs merged)
      aKeys = map fst a
      bOnlyKeys = filter (`notElem` aKeys) (map fst b)
  in mergedKeys === aKeys ++ bOnlyKeys
prop_merge_key_order _ _ = property True  -- trivially holds for non-objects
```

**d) Lazy branch evaluation (from US-02-003 complexity notes):**

```haskell
-- Property: the non-taken branch of !$if is never evaluated
-- (errors in dead branches don't surface)
prop_if_lazy :: Bool -> Property
prop_if_lazy cond =
  let deadBranch = AstPreprocessingTag (TagVarLookup "nonexistent_var") m
      liveBranch = str "ok"
      ifNode = ppTag $ TagIf (bool cond) liveBranch deadBranch
      result = resolveAst emptyCtx ifNode
  in isRight result === True
```

**e) ANSI escape sequence well-formedness (from US-07-001):**

```haskell
-- Property: every ESC[ in error output is followed by a valid
-- SGR sequence terminated by 'm', and every colored span has a
-- matching reset
prop_ansi_wellformed :: EnhancedPreprocessingError -> Property
prop_ansi_wellformed err =
  let output = renderError ColorAlways err
  in countEscapes output === countResets output
```

### 2.2 Golden/Snapshot Specifications

Snapshot testing is already strong in iidy-hs (render snapshots and error snapshots compared against Rust). The requirements could be restructured to make this first-class.

**Current approach:** Test fixtures exist in `test/fixtures/` and `test/fixtures/errors/`, separate from requirements docs. The connection is implicit.

**Proposed approach -- embedded examples in requirements:**

Each user story would include one or more `Example` blocks with machine-parseable input/output pairs:

```markdown
**Example: US-02-003-ex1** (truthiness-zero-is-truthy)

Input:
```yaml
$defs:
  val: 0
body: !$if
  test: !$ val
  then: "truthy"
  else: "falsy"
```

Expected output:
```yaml
body: "truthy"
```
```

These examples would be extractable by a script that:
1. Scans all `docs/requirements/*.md` files
2. Extracts `**Example: US-XX-NNN-exN**` blocks
3. Generates test fixture files or inline test cases
4. Runs the preprocessor and compares output

**Organization:** Group snapshots by requirement ID, not by test module. A directory structure like:

```
test/golden/
  US-02-001/     # $defs and $imports
    basic.yaml -> basic.expected.yaml
    empty-defs.yaml -> empty-defs.expected.yaml
  US-02-003/     # conditionals
    zero-is-truthy.yaml -> zero-is-truthy.expected.yaml
    nested-if.yaml -> nested-if.expected.yaml
  US-05-005/     # create-or-update
    exists-no-changeset.events -> exists-no-changeset.expected.events
```

This makes coverage gaps visible: if `US-02-004/` has no golden tests for `!$groupBy`, that is immediately apparent.

### 2.3 Type-Level Specifications

Haskell's type system can encode some invariants statically.

**a) Phantom types for pipeline phases:**

The requirement that "Phase 1 (I/O-bound) completes before Phase 2 (pure)" could be enforced:

```haskell
data Phase = Raw | Imported | Resolved

newtype Doc (p :: Phase) = Doc OValue

loadImports :: Doc 'Raw -> IO (Doc 'Imported)
resolveTags :: Doc 'Imported -> Either Error (Doc 'Resolved)

-- This won't compile:
-- resolveTags (Doc rawDoc :: Doc 'Raw)  -- type error
```

**b) NonEmpty for merge inputs:**

`!$merge` requires at least one mapping. Currently validated at runtime; could use `NonEmpty`:

```haskell
data TagMerge = TagMerge (NonEmpty YamlAst)  -- type-level guarantee
```

**c) Refined error codes:**

The error codes span specific ranges (1xxx-9xxx). A newtype with a smart constructor:

```haskell
newtype ErrorCode = ErrorCode Word16

mkErrorCode :: Word16 -> Maybe ErrorCode
mkErrorCode n
  | n >= 1001 && n <= 9005 = Just (ErrorCode n)
  | otherwise = Nothing
```

**d) GADTs for output events:**

The `OutputData` variants could carry type-level evidence of which operation emits them:

```haskell
data OpKind = Create | Update | Delete | Describe | ...

data OutputData (op :: OpKind) where
  OdStackDefinition :: StackDef -> OutputData op          -- any op
  OdPollingStarted  :: Text -> OutputData op              -- any op
  OdChangeSetResult :: ChangeSetInfo -> OutputData 'Update  -- update only
```

This is likely over-engineering for a CLI tool, but it illustrates the principle. The pragmatic recommendation is to use phantom types for the pipeline phases and `NonEmpty` for collection tags.

### 2.4 Formal Specifications

The existing PLT Redex spec covers preprocessing. Extensions and alternatives:

**a) Extend PLT Redex with a unified language:**

The spec currently cannot compose Handlebars, JMESPath, and preprocessing in a single evaluation. Defining `Iidy-Full` as a union language would allow end-to-end formal evaluation:

```racket
(define-extended-language Iidy-Full Iidy-Preprocess
  ;; Import Handlebars non-terminals
  (tmpl ::= (tp ...))
  (tp   ::= (hb-literal s) | (hb-output hx) | ...)
  ;; Import JMESPath non-terminals
  (jx   ::= (jfield s) | (jindex i) | ...))
```

This would close the composition gap documented in `spec/README.md` and allow formal verification of expressions like `{{#each items}}{{name}}{{/each}}` within a preprocessing context.

**b) TLA+ for CloudFormation operation state machines:**

The polling loops in `05-cfn-operations.md` are effectively state machines. TLA+ would be appropriate for verifying:
- All terminal states are reachable
- No operation can poll indefinitely (liveness)
- The create-or-update routing covers all `(exists, useChangeset, status)` combinations

```tla
VARIABLES state, exists, useChangeset, confirmed

Init ==
  /\ state = "start"
  /\ exists \in {TRUE, FALSE}
  /\ useChangeset \in {TRUE, FALSE}
  /\ confirmed \in {TRUE, FALSE}

CreateOrUpdate ==
  /\ state = "start"
  /\ IF ~exists /\ ~useChangeset THEN state' = "creating"
     ELSE IF ~exists /\ useChangeset THEN state' = "creating_changeset"
     ELSE IF exists /\ ~useChangeset THEN state' = "updating"
     ELSE state' = "updating_changeset"
  /\ UNCHANGED <<exists, useChangeset, confirmed>>

Spec == Init /\ [][CreateOrUpdate \/ Poll \/ Complete]_vars
```

**c) Alloy for import graph acyclicity:**

The circular import detection (ERR_3004) is a graph property. Alloy can verify the detection algorithm is correct for all graph shapes up to a bound:

```alloy
sig File { imports: set File }
fact noSelfImport { no f: File | f in f.imports }
pred circular { some f: File | f in f.^imports }
assert detectsAllCycles {
  circular => some f: File | f in f.^imports and detectionFires[f]
}
check detectsAllCycles for 6
```

**Cost/benefit:** The PLT Redex extension is high value (covers the most complex subsystem). TLA+ for CFN operations is moderate value (the state machines are simple but the routing logic is subtle). Alloy for imports is low value (the cycle detection is straightforward DFS).

### 2.5 Contract Specifications

Pre/post-conditions on key functions, checkable at test time via assertions or a lightweight contract library.

**a) Preprocessing pipeline contracts:**

```haskell
-- Pre: input is valid YAML (parses without error)
-- Post: output contains no $defs, $imports, $params, or $envValues keys
-- Post: output contains no !$ tags (all resolved or errored)
-- Post: output contains no {{ }} expressions (all interpolated)
preprocessContract :: OValue -> Either Error OValue -> Bool
preprocessContract _input (Left _) = True  -- errors are allowed
preprocessContract _input (Right output) =
  noSpecialKeys output && noPreprocessingTags output && noHandlebarsExprs output
```

**b) Merge contracts (from US-02-004):**

```haskell
-- Pre: all inputs are OObject
-- Post: result is OObject
-- Post: result keys are superset of all input keys
-- Post: result values for shared keys come from rightmost input
mergeContract :: [OValue] -> OValue -> Bool
mergeContract inputs result =
  all isOObject inputs ==>
    isOObject result
    && allKeysPresent inputs result
    && rightBiased inputs result
```

**c) Error display contracts (from US-07-001):**

```haskell
-- Post: output starts with error type in expected format
-- Post: output contains "ERR_XXXX" matching the error's code
-- Post: output ends with "For more info: iidy explain ERR_XXXX"
-- Post: line numbers in gutter are right-aligned, 4 chars wide
errorDisplayContract :: EnhancedPreprocessingError -> Text -> Bool
errorDisplayContract err output =
  hasErrCode (errorId err) output
  && hasFooter (errorId err) output
  && allGutterNumbersAligned output
```

These contracts can be checked as assertions in existing tests (zero extra test infrastructure) or run as a QuickCheck property over generated errors.

### 2.6 Decision Table Specifications

Several requirements contain implicit decision tables that should be made explicit and used to generate exhaustive test cases.

**a) Create-or-update routing (US-05-005):**

Already has an explicit table. Extend it with all observable outcomes:

| exists | useChangeset | ROLLBACK_COMPLETE | Action                  | Exit Code | Events Emitted               |
|--------|-------------|-------------------|-------------------------|-----------|------------------------------|
| F      | F           | N/A               | createStack             | 0/1       | Def, Polling, Events, Complete, Contents |
| F      | T           | N/A               | CREATE changeset+exec   | 0/1/130   | Def, ChangeSet, Polling...   |
| T      | F           | N/A               | updateStack             | 0/1       | Def, Polling, Events, Complete, Contents |
| T      | T           | N/A               | UPDATE changeset+exec   | 0/1/130   | Def, ChangeSet, Polling...   |
| T*     | F           | Yes               | createStack (treat absent) | 0/1    | Def, Polling, Events, Complete, Contents |

Each row generates a test case. Missing rows indicate coverage gaps.

**b) Color detection (from US-07-001 / US-12-xxx):**

| `--color` flag | `NO_COLOR` env | `FORCE_COLOR` env | stderr is TTY | Result        |
|----------------|----------------|--------------------|----|---------------|
| `always`       | *              | *                  | *  | Color enabled |
| `never`        | *              | *                  | *  | Color disabled|
| `auto`         | set            | unset              | *  | Color disabled|
| `auto`         | unset          | set                | *  | Color enabled |
| `auto`         | unset          | unset              | T  | Color enabled |
| `auto`         | unset          | unset              | F  | Color disabled|

**c) Template size routing (from US-05-001):**

| Template size   | S3 bucket configured | Action               |
|-----------------|---------------------|----------------------|
| <= 51200 bytes  | *                   | Inline template body |
| > 51200 bytes   | Yes                 | Upload to S3, use URL|
| > 51200 bytes   | No                  | Error                |

**d) Import type dispatch (from US-03-xxx):**

| URI scheme      | File extension | Loader    | Parser              |
|-----------------|---------------|-----------|---------------------|
| (none/relative) | .yaml/.yml    | File      | YAML                |
| (none/relative) | .json         | File      | JSON                |
| `http://`       | *             | HTTP      | Content-Type header |
| `s3://`         | *             | S3        | Extension-based     |
| `ssm://`        | *             | SSM       | String value        |
| `cfn://`        | *             | CFN       | Stack outputs       |
| `env://`        | *             | Env       | String value        |
| `git://`        | *             | Git clone | Extension-based     |

A test generator reads the table and produces one test per row:

```haskell
generateDecisionTableTests :: DecisionTable -> [TestTree]
generateDecisionTableTests dt =
  [ testCase (showRow row) (verifyRow row) | row <- dtRows dt ]
```

---

## 3. Workflow Improvements for Ports/Implementations

### 3.1 Requirements as Executable Specs

The ideal: requirements documents that ARE the test suite, or that generate it deterministically.

**Approach: Literate requirements with embedded test vectors.**

A requirements document would contain markdown prose for humans and fenced code blocks with a machine-readable marker for tooling:

```markdown
### US-02-003: Conditional logic

**Acceptance Criteria:**
- Zero is truthy in iidy's truthiness model.

<!-- @test US-02-003-AC-5: zero-is-truthy -->
```yaml
input:
  $defs:
    val: 0
  result: !$if
    test: !$ val
    then: "yes"
    else: "no"
expected:
  result: "yes"
```
<!-- @endtest -->
```

A script (`scripts/extract-requirement-tests.py`) would:
1. Parse all `<!-- @test ... -->` blocks from requirements docs
2. Generate YAML fixture files in `test/golden/requirements/`
3. Generate a Haskell test module that runs each fixture through the preprocessor
4. Report which requirements have zero embedded tests (coverage gap)

**Benefits:**
- Requirements and tests cannot drift apart -- they are the same artifact
- New requirements automatically generate test stubs
- Coverage gaps are visible at the requirements level, not just the code level

### 3.2 Conformance Testing Pipeline

For a port from Language A (Rust) to Language B (Haskell), the conformance pipeline should be:

```
                 Reference Implementation (Rust)
                           |
                 [Generate golden outputs]
                           |
                    golden-corpus/
                    input-001.yaml -> output-001.yaml
                    input-001.yaml -> stderr-001.txt
                    input-001.yaml -> exit-001.txt
                           |
                 [Run port against same inputs]
                           |
                    port-output/
                    input-001.yaml -> output-001.yaml
                    input-001.yaml -> stderr-001.txt
                    input-001.yaml -> exit-001.txt
                           |
                 [Diff golden vs port]
                           |
                    conformance-report.json
                    { "total": 500, "pass": 498, "fail": 2,
                      "failures": [
                        {"input": "input-042.yaml",
                         "diff": "- 'foo'\n+ 'Foo'",
                         "requirement": "US-02-004"}
                      ]}
```

**iidy-hs already does this** for render snapshots (via `scripts/snapshot-compare.sh`) and error snapshots (via `scripts/error-snapshot-compare.sh`). The improvement would be:

1. **Expand the corpus.** Golden comparisons are good but modest relative to the full test suite. Every requirement example block should have a golden comparison.

2. **Tag each golden case with a requirement ID.** Currently golden tests are organized by subsystem, not by requirement. Adding a metadata line to each fixture (`# requirement: US-02-003`) enables automated coverage reporting.

3. **Automate corpus generation.** A script that runs the Rust implementation against all fixture inputs and captures `(stdout, stderr, exit_code)` triples. This corpus becomes a versioned artifact.

4. **Differential fuzzing.** Feed random YAML documents to both implementations and compare outputs. This catches behaviors not covered by hand-written fixtures.

### 3.3 Progressive Verification

When building a port incrementally (as iidy-hs did across 16 phases), verification should be incremental too.

**Phase gate checklist:**

```
Phase N: Implement feature X
  [ ] Requirements review: all US-XX-NNN acceptance criteria understood
  [ ] Decision tables extracted and committed
  [ ] Golden corpus entries for feature X passing against reference
  [ ] Property tests for algebraic laws of feature X
  [ ] Error code coverage: all ERR_XXXX codes in scope have trigger tests
  [ ] Spec conformance: PLT Redex snapshot covers feature X drift points
  [ ] Integration: feature X composes correctly with features 1..N-1
```

**Monotonic test count:** Tests should only increase. A phase gate check:

```bash
BEFORE=$(cabal test 2>&1 | grep -o '[0-9]* test(s) run' | grep -o '[0-9]*')
# ... implement phase ...
AFTER=$(cabal test 2>&1 | grep -o '[0-9]* test(s) run' | grep -o '[0-9]*')
[ "$AFTER" -ge "$BEFORE" ] || echo "ERROR: test count decreased"
```

### 3.4 Cross-Implementation Snapshot Comparison

Best practices, drawing from iidy-hs's experience:

**a) Normalize before comparing.** Different implementations may produce semantically identical but textually different output (key ordering, whitespace, numeric formatting). Define a normalization function:

```bash
normalize() {
  # Sort JSON keys, normalize floats, strip trailing whitespace
  yq -P '.' "$1" | sed 's/[[:space:]]*$//'
}
diff <(normalize rust-output.yaml) <(normalize haskell-output.yaml)
```

**b) Three-level comparison:**

| Level       | Compares                    | Tolerance               |
|-------------|----------------------------|-------------------------|
| Byte-exact  | Raw stdout/stderr          | Zero (gold standard)    |
| Semantic    | Parsed YAML/JSON values    | Key order, whitespace   |
| Behavioral  | Exit code + error presence | Format differences OK   |

Start at behavioral (coarsest), tighten to semantic, aim for byte-exact. iidy-hs targets byte-exact, which is the right choice for a tool whose output is consumed by both humans and machines.

**c) Version-pin the reference.** Golden outputs should be generated from a specific commit of the reference implementation and stored in version control. Regeneration is a manual step, not automatic.

**d) Document known divergences.** iidy-hs has `DIVERGENCES.md` for intentional differences. Each divergence entry should reference the requirement it deviates from and the justification.

### 3.5 Specification-Driven Development with AI Agents

For an AI agent to implement AND verify a feature without human intervention, the requirements must be:

**a) Self-contained.** Every requirement must include enough context to implement without reading other requirements. Cross-references should be explicit (`see US-02-003 for truthiness definition`) rather than implicit.

**b) Testable without external dependencies.** If a requirement involves AWS, it must include mock data sufficient to test. The requirement for `createStack` should include a mock API response fixture.

**c) Structured for extraction.** An AI agent needs to parse the requirement into:
- **Preconditions:** What state must exist before the action
- **Action:** What function/command to invoke
- **Postconditions:** What to assert about the result
- **Error conditions:** What inputs produce errors, and what errors

This maps to a structured format (see Section 5).

**d) Verification criteria machine-readable.** Instead of "exit code 0 if CREATE_COMPLETE, else 1", provide:

```yaml
verification:
  - condition: status == "CREATE_COMPLETE"
    assert_exit_code: 0
  - condition: status != "CREATE_COMPLETE"
    assert_exit_code: 1
```

**e) Incremental checkpoint protocol.** An AI agent should be able to:
1. Read requirement US-XX-NNN
2. Implement it
3. Run the associated tests (and only those tests)
4. Get pass/fail feedback
5. Iterate or move to the next requirement

This requires requirements to have associated test suites that can be run independently.

### 3.6 The Role of Formal Semantics

**When formal specs are worth the investment:**

| Criterion                              | Formal spec worthwhile? |
|----------------------------------------|------------------------|
| Semantics are subtle and easy to get wrong | Yes -- truthiness variants, merge ordering |
| Multiple implementations must agree    | Yes -- Rust/Haskell conformance |
| The spec is small relative to the impl | Yes -- Redex spec is small relative to Haskell preprocessing |
| Properties are algebraic (commutative, associative, etc.) | Yes -- merge, concat |
| The domain is well-understood and stable | Yes -- YAML preprocessing is fixed |
| The domain involves concurrency or timing | Maybe -- TLA+ for polling, but iidy's concurrency is trivial |
| The domain is UI/output formatting     | No -- formal specs for ANSI rendering are not cost-effective |
| The implementation is a thin wrapper around a library | No -- JSON Schema validation just delegates |

**iidy-hs verdict:** The PLT Redex spec was a good investment. It caught the truthiness-of-zero divergence and the merge key-ordering subtlety. Extending it to compose sub-languages (Section 2.4a) would have moderate value. Adding TLA+ for CFN operations would have low value given their simplicity.

---

## 4. Concrete Recommendations for iidy-hs

### 4.1 Requirements Most Needing Reformulation

**Priority 1: Preprocessing tags (02-yaml-preprocessing.md)**

This is the most complex subsystem and benefits most from:
- Embedded input/output examples in each US (currently absent from the requirements doc)
- Decision tables for truthiness, type coercion, and edge case behavior
- Direct links to PLT Redex rules (e.g., "formalized as E-If in `semantics/eval.rkt`")

**Priority 2: CFN operations (05-cfn-operations.md)**

The 5-path create-or-update routing and the polling state machine would benefit from:
- Complete decision tables (the existing one for create-or-update is good but needs exit code and events columns)
- Event emission sequence specifications (which `OutputData` variants, in what order)
- Mock API response fixtures embedded in the requirement

**Priority 3: Error handling (07-error-handling.md)**

The error codes would benefit from:
- One trigger fixture per error code (some exist in `test/fixtures/errors/`, but completeness is unclear)
- Machine-parseable display format specification (regex or structural grammar for the error output)

### 4.2 Verification Gaps Today

| Gap                                         | Impact  | Fix                                      |
|---------------------------------------------|---------|------------------------------------------|
| No traceability from AC bullets to tests    | High    | Add `# requirement: US-XX-NNN` to tests  |
| Decision tables only for create-or-update   | Medium  | Extract tables for color, import, template size |
| PLT Redex doesn't compose sub-languages     | Medium  | Build `Iidy-Full` union language         |
| No differential fuzzing against Rust        | Medium  | Random YAML generator + dual-run comparison |
| Error display format tested by snapshot only | Low    | Add structural contracts (Section 2.5c)  |
| No automated coverage report per requirement | High   | Script to count tests per US-XX-NNN      |

### 4.3 What "Verification-First" Requirements Would Look Like

A verification-first requirement for US-02-003 (conditionals):

```markdown
### US-02-003: Conditional logic (!$if, !$eq, !$not)

#### Formal Semantics
- E-If: `semantics/eval.rkt` lines 45-52
- Truthiness: `semantics/truthiness.rkt`

#### Decision Table: !$if

| test value   | truthiness | then   | else   | result |
|-------------|------------|--------|--------|--------|
| true        | truthy     | "yes"  | "no"   | "yes"  |
| false       | falsy      | "yes"  | "no"   | "no"   |
| ""          | falsy      | "yes"  | "no"   | "no"   |
| 0           | truthy     | "yes"  | "no"   | "yes"  |
| null        | falsy      | "yes"  | absent | null   |
| [1,2]       | truthy     | "yes"  | "no"   | "yes"  |
| []          | falsy      | "yes"  | "no"   | "no"   |

#### Properties
- P1: `!$if test=X then=A else=B` with truthy X === A (branch selection)
- P2: `!$if test=X then=A else=B` with falsy X === B (branch selection)
- P3: `!$not (!$not X)` has same truthiness as X (double negation)
- P4: Error in non-taken branch does not surface (lazy evaluation)

#### Test Vectors
[Embedded YAML input/output pairs as in Section 3.1]

#### Error Triggers
- ERR_4002: `!$if {then: "x"}` (missing test field)
- ERR_4003: `!$if "not a mapping"` (wrong type)

#### Implementation Trace
- Haskell: `Iidy.Yaml.Resolution.Resolver.resolveTag` case `TagIf`
- Rust: `src/yaml/resolution/tags.rs` fn `resolve_if`
- Redex: `semantics/eval.rkt` judgment `E-If`
```

### 4.4 Extending the PLT Redex Spec

**Extension 1: Compose sub-languages into Iidy-Full.**
This is the highest-value extension. It would allow formal verification of:
- Handlebars expressions inside preprocessing contexts
- JMESPath queries applied to preprocessed values
- Bracket expansion within variable paths

**Extension 2: Add import graph semantics.**
Model the `$imports` resolution as a judgment over a file-system model:

```racket
(define-judgment-form Iidy-Imports
  #:mode (resolve-imports I I O O)
  #:contract (resolve-imports σ fs σ' manifest)
  ...)
```

**Extension 3: Generate more snapshot vectors.**
Currently vectors cover 7 areas. Adding vectors for:
- All tag forms (not just the subset currently covered)
- Handlebars helper functions (none in snapshot)
- JMESPath query patterns (none in snapshot)

would increase confidence without requiring Racket in CI.

---

## 5. Proposed Requirements Document Format

### 5.1 Format Specification

```markdown
# REQ-<module>-<NNN>: <Title>

## Metadata
- **Module:** <02-yaml-preprocessing | 05-cfn-operations | ...>
- **Personas:** Developer, CI Pipeline
- **Formal spec:** semantics/eval.rkt#E-If (optional)
- **Impl trace:** Iidy.Yaml.Resolution.Resolver.resolveTag/TagIf
- **Error codes:** ERR_4002, ERR_4003

## Description
<1-3 paragraphs of prose for human consumption>

## Decision Table
<!-- @decision-table REQ-02-003 -->
| test     | then  | else    | result | exit |
|----------|-------|---------|--------|------|
| truthy X | A     | B       | A      | 0    |
| falsy X  | A     | B       | B      | 0    |
| falsy X  | A     | (none)  | null   | 0    |
<!-- @end-decision-table -->

## Properties
<!-- @property REQ-02-003-P1 -->
forall X, A, B:
  truthy(X) => eval(!$if {test: X, then: A, else: B}) == eval(A)
<!-- @end-property -->

<!-- @property REQ-02-003-P2 -->
forall X:
  truthy(!$not(!$not(X))) == truthy(X)
<!-- @end-property -->

## Test Vectors
<!-- @test-vector REQ-02-003-TV1: zero-is-truthy -->
```yaml
input:
  $defs:
    val: 0
  body: !$if
    test: !$ val
    then: "yes"
    else: "no"
expected:
  body: "yes"
exit_code: 0
```
<!-- @end-test-vector -->

<!-- @test-vector REQ-02-003-TV2: missing-test-field -->
```yaml
input:
  body: !$if
    then: "x"
expected_error: ERR_4002
```
<!-- @end-test-vector -->

## Edge Cases
<!-- @edge-case REQ-02-003-EC1 -->
- Zero is truthy (diverges from many languages). Verified by TV1.
<!-- @end-edge-case -->

## Contracts
<!-- @contract REQ-02-003-C1: post -->
Output of !$if never contains !$if tags (all resolved).
<!-- @end-contract -->
```

### 5.2 Tooling

A `requirements-tool` CLI (could be Haskell, Python, or Nushell) that:

| Command                           | Action                                                    |
|-----------------------------------|-----------------------------------------------------------|
| `req extract-tests`              | Generate test fixtures from `@test-vector` blocks          |
| `req extract-tables`            | Generate exhaustive test cases from `@decision-table` blocks |
| `req coverage-report`           | Cross-reference test names with REQ IDs, find gaps         |
| `req trace`                     | Verify impl-trace paths exist in source                    |
| `req validate`                  | Check all `@property` blocks have corresponding QC tests   |
| `req lint`                      | Ensure all error codes referenced have trigger test vectors |
| `req diff <old-req> <new-req>` | Show semantic diff between requirement versions            |

### 5.3 Completeness Checking

An automated completeness check would verify:

1. **Every requirement has at least one test vector.** `req extract-tests | wc -l >= number_of_requirements`
2. **Every error code has a trigger test vector.** `grep -c 'expected_error:' | sort | compare to error-code-table`
3. **Every decision table row has a corresponding test.** `req extract-tables | verify each row has a matching TV`
4. **Every property has a corresponding QuickCheck test.** `grep '@property' requirements/ | compare to test/Test/*PropertyTest.hs`
5. **Every formal spec rule has a snapshot vector.** `grep 'E-' spec/semantics/eval.rkt | compare to spec/snapshot.json sections`

### 5.4 Human Readability

The format preserves human readability because:
- Machine-readable blocks are inside HTML comments (`<!-- @... -->`) or fenced code blocks
- The prose description, edge cases, and complexity notes remain natural language
- Decision tables are standard markdown tables
- The format degrades gracefully in any markdown renderer

### 5.5 Integration with AI Agent Workflows

An AI agent implementing a requirement would:

1. `req show REQ-02-003` -- read the full requirement
2. `req extract-tests REQ-02-003` -- get the test vectors for this requirement
3. Implement the feature
4. `cabal test --test-option='-p REQ-02-003'` -- run only the associated tests
5. `req coverage-report REQ-02-003` -- verify all ACs, TVs, properties covered
6. If all pass, move to next requirement

This gives the agent a tight, automated feedback loop without requiring human review at each step.

---

## 6. Summary

The iidy-hs requirements are well-structured for human consumption but only partially machine-verifiable. The main gaps are:

1. **No embedded test vectors in requirements** -- tests exist but are disconnected from the requirements they verify.
2. **Decision tables are rare** -- only create-or-update has one explicitly; many other branching behaviors are described in prose.
3. **No automated traceability** -- no mechanism to verify that every acceptance criterion has a corresponding test.
4. **PLT Redex covers preprocessing but not operations** -- the most complex subsystem is formally specified, but CFN operations, output formatting, and error display are not.

The proposed format (Section 5) addresses all four gaps while preserving human readability. The key insight is that **requirements and tests should be the same artifact** -- a requirement without an embedded test vector is untestable by definition, and a test without a requirement reference is untraced.

For AI-driven ports specifically, the most impactful change would be making every requirement self-contained with embedded test vectors, so an agent can implement and verify one requirement at a time without maintaining global state about the test suite.
