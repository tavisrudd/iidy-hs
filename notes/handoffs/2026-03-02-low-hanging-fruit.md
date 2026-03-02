# Low-Hanging Fruit: No-Debate Improvements

**Date**: 2026-03-02
**Scope**: Items from the architecture reviews and refactoring plan that have zero downsides
**Estimated**: 5 commits, ~8 files touched, 1-2 sessions

---

## Selection Criteria

Every item here passes all three filters:

1. **No regression risk** — either additive (new tests/docs) or fixes a real bug
2. **No debate** — no reviewer or critique argues against it; no design trade-offs to resolve
3. **Small scope** — each item is self-contained and completable in one commit

Items from the 10-phase refactoring plan that involve threading new types through 15+ files,
splitting modules, or changing function signatures are explicitly excluded — those have real
risk and debatable payoff.

---

## Chunk 1: Property Tests for Preprocessing Tags

**Source**: Krishnamurthi review, refactoring plan Phase 6.1
**Why no downside**: New test file. Can't break anything. If a property fails, it found a real bug.

### What to do

Create `test/Test/Iidy/Yaml/Resolution/PropertyTests.hs` with these properties:

| Property                        | What it tests                                                    |
|---------------------------------|------------------------------------------------------------------|
| `!$merge` right-bias            | `lookup key (merge [a, b]) == lookup key b` for all keys in `b`  |
| `!$merge` identity              | `merge [a, {}] == a` and `merge [{}, a] == a`                    |
| `!$map` preserves length        | `length(map(f, xs)) == length(xs)`                               |
| `!$concat` associativity        | `concat [concat [a,b], c]` same elements as `concat [a, concat [b,c]]` |
| `!$let` scoping                 | Inner bindings shadow outer: `let x=1 in (let x=2 in x) == 2`   |
| `!$if` branch selection         | Only the selected branch is evaluated (put error in other branch)|
| Resolution idempotency          | Resolving a fully-resolved document again produces same result   |
| CFN tag pass-through            | `!Ref`, `!Sub` etc. pass through resolution unchanged            |

### Implementation notes

- Read `test/Test/PropertyTest.hs` for existing generator patterns
- Read `Resolver.hs` to understand how to construct test ASTs programmatically
- The resolver is pure (`resolveAst :: TagContext -> YamlAst -> Either ResolveError OValue`),
  so property tests can be fully pure — no IO needed
- Register in the test suite module tree
- Run `cabal test` — if any property fails, **that's a real bug to fix before committing**

### Files touched
- 1 new: `test/Test/Iidy/Yaml/Resolution/PropertyTests.hs`
- 1 edit: test registration (e.g., `test/Main.hs` or relevant test module)

---

## Chunk 2: Error Content Tests in `cabal test`

**Source**: Krishnamurthi review, refactoring plan Phase 6.3
**Why no downside**: New test file. Makes CI catch what only the shell script catches today.

### What to do

Create `test/Test/Iidy/Yaml/Errors/ContentTests.hs`:

- For each of the 49 error snapshot fixtures, add a test that:
  1. Runs the preprocessing pipeline on the fixture input
  2. Extracts the error
  3. Asserts **key content** (error code, key phrase, file/line reference)
- These are NOT full snapshot comparisons (those stay in the external script)
- These are **content assertions**: "error contains ERR_2001", "error mentions variable 'foo'"
- Looser than snapshots, so robust to minor formatting changes

### Implementation notes

- Read existing error test patterns in the test suite
- Read `scripts/error-snapshot-compare.sh` to understand the fixture layout
- Error fixtures are in `test/fixtures/errors/` (verify exact path)
- Run `cabal test` — all 49 assertions must pass

### Files touched
- 1 new: `test/Test/Iidy/Yaml/Errors/ContentTests.hs`
- 1 edit: test registration

---

## Chunk 3: JMESPath Subset Documentation + Better Parse Errors

**Source**: Krishnamurthi review, refactoring plan Phase 6.2
**Why no downside**: Documentation is pure additive. Parser error improvement only affects
invalid expressions (valid expressions are untouched).

### What to do

**Part A — Documentation:**

Create `notes/jmespath-subset.md`:
- List every `JExpr` constructor in `src/Iidy/Yaml/JMESPath.hs` (the supported forms)
- Cross-reference against the JMESPath spec (jmespath.org)
- Explicitly list what's NOT supported:
  - Built-in functions (all 30+): `length()`, `keys()`, `values()`, `sort()`, etc.
  - Object wildcard: `.*`
  - Slice expressions: `[0:5]`, `[::2]`
- Add a section to `DIVERGENCES.md` documenting this subset

**Part B — Parser errors:**

In `src/Iidy/Yaml/JMESPath.hs`:
- When the parser encounters `(` (function call syntax), emit:
  `"JMESPath functions are not supported in iidy. Expression: length(@)"`
- When encountering `[n:m]` (slice syntax), emit:
  `"JMESPath slice expressions are not supported in iidy."`
- Add 2-3 tests for the improved error messages

### Files touched
- 1 new: `notes/jmespath-subset.md`
- 1 edit: `DIVERGENCES.md`
- 1 edit: `src/Iidy/Yaml/JMESPath.hs` (parser error paths only)
- 1 edit: JMESPath test file (add tests for new error messages)

---

## Chunk 4: `!$expand` Cycle Detection

**Source**: Krishnamurthi review, handoff self-critique point #6
**Why no downside**: Fixes a real latent infinite loop. ~10 lines of code.

### What to do

The import system has cycle detection via `ImportStack`. Template expansion (`!$expand`) has
none. A custom resource that expands to itself loops forever.

In the resolver's expansion path:
- Add a `Set Text` of currently-active expansion names to the resolution context (or thread
  it through the expansion function)
- Before expanding a template, check if its name is in the active set
- If yes, return a `ResolveError` like: `"Circular expansion detected: template 'X' is
  already being expanded"`
- If no, add the name to the set and proceed

### Implementation notes

- Read `Resolver.hs` — find where `!$expand` / custom resource expansion happens
- The `TagContext` already carries state through resolution; adding `tcActiveExpansions :: Set Text`
  is the natural place
- The `ImportStack` in `Iidy/Yaml/Imports/ImportStack.hs` is the model to follow
- Add a test: create a fixture with a circular custom resource, verify it produces an error
  instead of hanging

### Files touched
- 1 edit: `src/Iidy/Yaml/Resolution/Resolver.hs` (or `TagContext` definition)
- 1 edit: wherever `TagContext` is defined (add the `Set Text` field)
- 1 new or edit: test for circular expansion error

---

## Chunk 5: OutputFormat Enum (Phase 1.3 from the Plan)

**Source**: Minsky review, refactoring plan Phase 1.3
**Why no downside**: Fixes a real UX bug. `--format josn` currently gives silent YAML output
instead of an error. After this change, the user gets a clear "Unknown format" error at
CLI parse time.

### What to do

- In `Iidy.Types` (or wherever format types live): add
  ```haskell
  data OutputFormat = FormatJson | FormatYaml | FormatCfnYaml
    deriving (Show, Eq)

  parseOutputFormat :: Text -> Either Text OutputFormat
  parseOutputFormat = \case
    "json"                -> Right FormatJson
    "yaml"                -> Right FormatYaml
    "yml"                 -> Right FormatYaml
    "yaml-cloudformation" -> Right FormatCfnYaml
    other                 -> Left $ "Unknown output format: " <> other
                                  <> ". Valid formats: json, yaml, yaml-cloudformation"
  ```
- In `Iidy.Cli`: change `raFormat :: !Text` to `raFormat :: !OutputFormat` in `RenderArgs`,
  and `giaFormat :: !Text` to `giaFormat :: !OutputFormat` in `GetImportArgs`
- In `Iidy.Cli.Parser`: parse the format flag using `parseOutputFormat` at the CLI boundary
- In `Iidy.Render`: replace `case T.toLower (raFormat args) of "json" -> ...` with
  `case raFormat args of FormatJson -> ...` — remove the `_ -> emitYaml` wildcard
- In `Iidy.GetImport`: same pattern as Render
- Add a unit test for `parseOutputFormat` with valid and invalid inputs

### Files touched
- 1 edit: types file (add `OutputFormat` type)
- 1 edit: `Iidy.Cli` (field type changes)
- 1 edit: `Iidy.Cli.Parser` (parse at boundary)
- 1 edit: `Iidy.Render` (pattern match on enum)
- 1 edit: `Iidy.GetImport` (pattern match on enum)
- 1 edit: test file (add `parseOutputFormat` tests)

---

## Chunk 6: Investigate `saResourceTypes` (Research Only)

**Source**: Codebase exploration during review critique
**Why no downside**: Research only — no code changes until findings are evaluated.

### What to do

`saResourceTypes :: Maybe [Text]` in `StackArgs` is parsed from YAML in `StackArgsLoader`
but **never consumed by `RequestBuilder`**. The field is silently dropped.

1. Check the Rust source at `~/src/iidy/src/cfn/request_builder.rs` — does Rust pass
   `resourceTypes` to CloudFormation API calls?
2. Check the CloudFormation API — which operations accept `ResourceTypes`?
   (`CreateStack` does via `resourceTypes` parameter)
3. If Rust uses it and we don't: it's a port bug, file it for fix
4. If Rust also drops it: it's a shared design decision, document it in `DIVERGENCES.md`
5. If it maps to a CFN API parameter we're not passing: wire it through in `RequestBuilder`

### Files touched
- 0 (research only; fix committed separately if needed)

---

## Execution Order

```
Chunk 1: Property tests          — additive, may find bugs that inform later work
Chunk 2: Error content tests     — additive, strengthens safety net
Chunk 3: JMESPath docs + errors  — documentation + tiny parser fix
Chunk 4: !$expand cycle detection — real bug fix, ~10 lines
Chunk 5: OutputFormat enum       — real UX fix, small scope
Chunk 6: saResourceTypes research — just investigation
```

Chunks 1-2 go first because they're purely additive tests — they make the safety net
stronger before any code changes happen. Chunks 3-5 are small code changes under the
now-stronger test coverage. Chunk 6 is research that informs whether more work is needed.

---

## What This Does NOT Include

Everything excluded has either debatable payoff, non-trivial risk, or touches too many files:

| Excluded item                           | Why excluded                                       |
|-----------------------------------------|----------------------------------------------------|
| OnFailure enum (Phase 1.1)              | Theoretical bug in tested code; 3 files for no user-visible change |
| Capability enum (Phase 1.2)             | Same as above                                      |
| StackStatus type (Phase 2)              | 15-20 files for internal representation change     |
| TemplateLoader fail->Either (Phase 3)   | Changes error handling mechanism; behavior change  |
| CfnContext separation (Phase 4)         | 16+ files; prevents a bug that has never occurred  |
| OdRawOutput refinement (Phase 5)        | Adds types without removing old one                |
| StackArgsLoader extraction (Phase 7)    | New module for functions with 1 caller             |
| Emit callback cleanup (Phase 8)         | Low impact; Sts warning is rare                    |
| PollConfig refinement (Phase 9)         | Internal; invariant already held in practice       |
| SomeException narrowing (Phase 10)      | Needs per-site audit; can change failure modes     |
| Unified IidyError type                  | Highest impact but touches 30+ function signatures |
| ReaderT/ExceptT monad stack             | Rewrites the entire CFN layer                      |

These can be revisited after the low-hanging fruit is done, informed by whether the property
tests found any real issues.

---

## Progress

_To be filled in by executing agent._

## Handoff Notes

_To be filled in by executing agent._
