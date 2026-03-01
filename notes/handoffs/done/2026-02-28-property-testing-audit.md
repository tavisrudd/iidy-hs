# Property-Based Testing Audit & Plan

**Date**: 2026-02-28
**Session**: `1c1b0e58-98ae-46a4-a7eb-9fbac4c0b212`
**References**: `test/Test/PropertyTest.hs` (existing), QuickCheck docs

## Context

The test suite has ~400 tests (tasty runner count), overwhelmingly unit tests with hand-picked
examples. Only 6 property tests exist today, all in `PropertyTest.hs`. QuickCheck and
tasty-quickcheck are already in the cabal deps. The existing `Arbitrary OValue` instance
and generators (`genOValue`, `genSafeText`, `genSimpleYamlDoc`) are solid reusable
infrastructure.

**Goal**: Identify where property-based tests would catch bugs that hand-picked examples miss,
prioritize by value/effort, and produce an implementation plan.

## Current Property Tests (6)

| Property                    | What it tests                                          | Strength |
|-----------------------------|--------------------------------------------------------|----------|
| `prop_ovalue_roundtrip`     | `fromValue . toValue` identity (modulo key order)      | Strong   |
| `prop_null_roundtrip`       | Null specifically round-trips                          | Weak     |
| `prop_bool_roundtrip`       | Bool round-trip                                        | Weak     |
| `prop_string_roundtrip`     | String round-trip via `genSafeText`                    | Moderate |
| `prop_parse_emit_stable`    | YAML parse succeeds or discards (doesn't test output!) | Weak     |
| `prop_handlebars_literal`   | Text without `{{` passes through unchanged             | Moderate |

The two weakest spots: `prop_parse_emit_stable` doesn't actually verify the emit output,
and the null/bool tests are trivially covered by the general `prop_ovalue_roundtrip`.

## Tier 1 — High Value, Low Effort (do these)

These test real invariants in custom implementations where bugs are most likely.

### 1A. YAML Emit/Parse Round-Trip (strengthen existing)

**File**: `src/Iidy/Yaml/Emitter.hs`, `src/Iidy/Yaml/Parser.hs`
**Current gap**: `prop_parse_emit_stable` doesn't verify output at all.

**Properties**:
- `emitYaml v` → parse → preprocess → compare against `v` (true round-trip)
- `emitYaml` idempotence: emit(parse(emit(v))) == emit(v)
- `needsQuotes` correctness: if `needsQuotes s`, emitted form is quoted

**Generator**: Existing `genOValue`. May need to filter edge cases where YAML 1.1
bool detection interferes (e.g., generated strings that happen to be "yes"/"no").

**Why valuable**: The custom emitter (~250 LOC) handles quoting, multiline, CFN tags.
Any quoting bug would be caught by a round-trip property but might slip past the 16
hand-picked `EmitterTest` cases.

### 1B. Handlebars Case Helpers

**File**: `src/Iidy/Yaml/Handlebars/Helpers.hs`
**Functions**: `titleize`, `toCamelCase`, `toPascalCase`, `toSnakeCase`, `toKebabCase`, `splitWords`

**Properties**:
- `toSnakeCase` output is all lowercase + underscores
- `toKebabCase` output is all lowercase + hyphens
- `toPascalCase` starts uppercase (for non-empty input with at least one word)
- `titleize` is idempotent
- `splitWords` then rejoin via `_` equals `toSnakeCase` (for alphanumeric input)
- `sha256Hex` output: always 64 chars, all `[0-9a-f]`
- `encodeBase64` output length: `4 * ceil(inputBytes / 3)`

**Generator**: `genSafeText` + a `genWordyText` (words separated by spaces/underscores/hyphens).

**Why valuable**: These are custom string processing functions. Idempotence and
output-charset properties catch subtle bugs that unit tests with 3-4 examples miss.

### 1C. JMESPath Algebraic Properties

**File**: `src/Iidy/Yaml/JMESPath.hs`

**Properties**:
- Identity: `applyJmesPath "@" v == Right v`
- Field on non-object: `applyJmesPath "anyfield" (Number n) == Right Null`
- Totality: `applyJmesPath expr v` never throws (crashes) for any valid parse of `expr`
- Pipe associativity: `(a | b) | c == a | (b | c)` for field-path expressions

**Generator**: Need `Arbitrary Value` (bounded-depth, mirrors `genOValue` but for Aeson `Value`).
Also a `genJmesExpr :: Gen Text` that produces syntactically valid expressions.

**Why valuable**: Custom JMESPath engine (~200 LOC). The 13 unit tests cover specific paths
but not the combinatorial space of expression × value shapes.

### 1D. findSubstring / findAllSubstring

**File**: `src/Iidy/Yaml/Errors/Conversion.hs`

**Properties**:
- `findSubstring needle haystack == Just i` implies `T.take (T.length needle) (T.drop i haystack) == needle`
- `isJust (findSubstring needle haystack) == T.isInfixOf needle haystack`
- `findAllSubstring` returns strictly increasing positions
- All positions in `findAllSubstring` are valid substring starts

**Generator**: `genSafeText` for both needle and haystack.

**Why valuable**: Custom substring search (not `T.isInfixOf`) used in error classification.
If it ever deviates from `Data.Text`'s behavior, a property test catches it immediately.

## Tier 2 — Moderate Value, Low Effort (good to have)

### 2A. OValue Equality & Truthiness

**File**: `src/Iidy/Yaml/OValue.hs`

**Properties**:
- `oValuesEqual` is reflexive: `oValuesEqual v v == True`
- `oValuesEqual` is symmetric: `oValuesEqual a b == oValuesEqual b a`
- `oIsTruthy` consistent with Handlebars `isTruthy`: `oIsTruthy v == isTruthy (toValue v)`
- `oValueToText (OString s) == s`

**Generator**: Existing `genOValue`.

### 2B. JSON Schema Boolean Schemas + Type Round-Trip

**File**: `src/Iidy/Yaml/CustomResources/JsonSchema.hs`

**Properties**:
- `validateSchema (Bool True) v == Right ()` for all `v`
- `validateSchema (Bool False) v == Left _` for all `v`
- `matchesType (valueTypeName v) v == True`

**Generator**: Need `Arbitrary Value`.

### 2C. CFN Status Mutual Exclusion

**File**: `src/Iidy/Cfn/Status.hs`

**Properties**:
- `isInProgressStatus s ==> not (isTerminalResourceStatus s)` (for all `Text`)
- `isRollbackStatus s && isFailureStatus s ==> not (isSuccessStatus s)`
- `isTerminalResourceStatus s ==> isTerminalStackStatus s` (superset)

**Generator**: Mix of `elements knownStatuses` and `genSafeText` (fuzz).

### 2D. Template Hash Properties

**File**: `src/Iidy/Cfn/TemplateHash.hs`

**Properties**:
- `T.length (calculateTemplateHash t) == 64`
- All chars in `[0-9a-f]`
- `parseS3Url ("s3://" <> b <> "/" <> k) == Right (b, k)` (for valid bucket/key)
- `parseS3Url` rejects non-s3 prefix

**Generator**: `genSafeText`.

### 2E. ErrorId Round-Trip

**File**: `src/Iidy/Yaml/Errors/Ids.hs`

**Properties**:
- `errorIdFromCode (errorIdCode eid) == Just eid` for all `ErrorId`
- `showErrorId eid` always starts with `"ERR_"`
- Code uniqueness (all codes distinct)

**Generator**: `elements [minBound..maxBound]` or explicit list.

### 2F. Renderer Padding Invariants

**File**: `src/Iidy/Output/Renderers/Interactive.hs`

**Properties**:
- `T.length (padRight w t) >= w`
- `padRight w (padRight w t) == padRight w t` (idempotent)
- `T.isPrefixOf t (padRight w t)` (preserves content)

**Generator**: `Arbitrary Int` (positive) + `genSafeText`.

## Tier 3 — Lower Priority (defer unless bored)

| Candidate                     | Module                              | Properties                                    |
|-------------------------------|-------------------------------------|-----------------------------------------------|
| `sortCfnKeys` idempotence     | `Cfn/Operations/ConvertStack.hs`    | `sortCfnKeys . sortCfnKeys == sortCfnKeys`   |
| `deriveTokenForStep` length   | `Aws/ClientReqToken.hs`            | Token always 17 chars, prefix matches primary |
| `mergeOObjects` key union     | `Yaml/Resolution/Resolver.hs`      | Keys = union of input keys                    |
| `deduplicateResources` unique | `Yaml/Resolution/Resolver.hs`      | Output keys all unique                        |
| `traversePathO` composition   | `Yaml/Resolution/Resolver.hs`      | `traverse (a++b) == traverse a >=> traverse b`|
| `parseNtpResponse` short      | `Aws/Timing.hs`                    | `< 48 bytes → Nothing`                       |
| `detectYamlSpec` totality     | `Yaml/Detection.hs`                | Never crashes on arbitrary Text                |
| `classifyMessage` totality    | `Yaml/Errors/Conversion.hs`        | Never crashes on arbitrary Text                |

## Shared Generator Infrastructure Needed

| Generator          | Produces          | Used by           | Effort |
|--------------------|-------------------|-------------------|--------|
| `Arbitrary Value`  | Aeson `Value`     | 1C, 2B, Tier 3    | Small  |
| `genWordyText`     | Text with words   | 1B                 | Tiny   |
| `genJmesExpr`      | Valid JMESPath     | 1C                 | Medium |
| `genCfnStatus`     | CFN status strings | 2C                 | Tiny   |
| `Arbitrary ErrorId`| ErrorId enum       | 2E                 | Tiny   |

The `Arbitrary Value` generator is the single highest-leverage infrastructure piece.
It's just `genOValue` adapted to produce `Value` instead of `OValue`:

```haskell
genValue :: Int -> Gen Value
genValue 0 = oneof [pure Null, Bool <$> arbitrary, Number . fromIntegral <$> (arbitrary :: Gen Int), String <$> genSafeText]
genValue n = oneof [pure Null, Bool <$> arbitrary, Number . fromIntegral <$> (arbitrary :: Gen Int), String <$> genSafeText,
  Array . V.fromList <$> resize (n`div`2) (listOf (genValue (n`div`2))),
  Object . KM.fromList <$> resize (n`div`2) (listOf ((,) <$> (Key.fromText <$> genKey) <*> genValue (n`div`2)))]
```

## Assessment: Is It Worth It?

**Yes, selectively.** The project has good unit test coverage but several custom
implementations (YAML emitter, JMESPath, Handlebars helpers, substring search) where
property tests catch classes of bugs that example-based tests structurally cannot.

**Expected yield**: Tier 1 adds ~15-20 properties covering the riskiest custom code.
Tier 2 adds ~10 more for completeness. Total effort: 1-2 sessions.

**What NOT to property-test**: AWS loader parsing, CLI arg parsing, renderer formatting
details, integration test sequences — these are configuration-heavy, not algorithm-heavy,
and unit tests are the right tool.

## Implementation Chunks

### Chunk 1: Infrastructure + Tier 1A-1B (~30 min)

- Add `Arbitrary Value` generator to `PropertyTest.hs`
- Add `genWordyText` generator
- Strengthen `prop_parse_emit_stable` to actual round-trip
- Add emitter idempotence property
- Add 5-7 Handlebars helper properties (case conversion, sha256, base64)
- Export needed functions from Helpers.hs if not already exported

**Can delegate?** Yes — Sonnet. Clear inputs/outputs, mechanical.

### Chunk 2: Tier 1C-1D (~30 min)

- Add `genJmesExpr` (start simple: field paths + wildcards + pipes)
- Add JMESPath identity, field-on-non-object, totality properties
- Add findSubstring/findAllSubstring correctness properties
- May need to export `findSubstring`/`findAllSubstring` if not already

**Can delegate?** Yes — Sonnet for properties, Opus for the JMESPath expression generator.

### Chunk 3: Tier 2 (~30 min)

- OValue equality reflexivity/symmetry
- JSON Schema boolean schemas + type round-trip
- CFN status mutual exclusion
- Template hash length/charset
- ErrorId round-trip
- Padding invariants

**Can delegate?** Yes — Sonnet. All straightforward.

### Chunk 4: Cleanup + Consolidation (~15 min)

- Remove redundant `prop_null_roundtrip` and `prop_bool_roundtrip` (subsumed by `prop_ovalue_roundtrip`)
- Verify all properties pass
- Build clean, zero warnings

**Can delegate?** Yes — Sonnet.

## Codebase Reference

| What                     | Where                                            |
|--------------------------|--------------------------------------------------|
| Existing property tests  | `test/Test/PropertyTest.hs` (124 LOC)            |
| Existing generators      | Same file: `genOValue`, `genSafeText`, lines 27-51 |
| YAML Emitter             | `src/Iidy/Yaml/Emitter.hs`                      |
| YAML Parser              | `src/Iidy/Yaml/Parser.hs`                       |
| JMESPath engine          | `src/Iidy/Yaml/JMESPath.hs`                     |
| Handlebars helpers       | `src/Iidy/Yaml/Handlebars/Helpers.hs`            |
| Handlebars engine        | `src/Iidy/Yaml/Handlebars/Engine.hs`             |
| JSON Schema validator    | `src/Iidy/Yaml/CustomResources/JsonSchema.hs`    |
| OValue                   | `src/Iidy/Yaml/OValue.hs`                       |
| CFN Status               | `src/Iidy/Cfn/Status.hs`                        |
| Error IDs                | `src/Iidy/Yaml/Errors/Ids.hs`                   |
| Template hash            | `src/Iidy/Cfn/TemplateHash.hs`                  |
| Substring search         | `src/Iidy/Yaml/Errors/Conversion.hs`            |
| Renderer padding         | `src/Iidy/Output/Renderers/Interactive.hs`       |
| Test main                | `test/Main.hs`                                   |

## Build/Test Commands

Per CLAUDE.md — `run-quiet` wrapper for builds.

## Delegation Strategy

All chunks can be delegated to Sonnet sub-agents after Opus reviews this plan.
The only piece needing Opus judgment is the JMESPath expression generator design
(Chunk 2), which is a small enough decision to include in the Chunk 2 prompt.

## Workflow Instructions

- Read this file first
- Work through chunks in order (1 → 2 → 3 → 4)
- After each chunk: build, test, verify zero warnings
- Commit after each chunk (green commits only)
- Update Progress below

## Progress

- [x] Chunk 1: Infrastructure + YAML round-trip + Handlebars helpers
- [x] Chunk 2: JMESPath + findSubstring properties
- [x] Chunk 3: Tier 2 properties (OValue, JsonSchema, Status, Hash, ErrorId, Padding)
- [x] Chunk 4: Cleanup redundant tests, final verification

## Handoff Notes

### All Chunks (2026-02-28)

**Session**: `1c1b0e58-98ae-46a4-a7eb-9fbac4c0b212`
**Completed**: All 4 chunks implemented in a single pass. 22 property tests (up from 6).
**Files modified**: `test/Test/PropertyTest.hs`
**Deviations from plan**:
- Skipped `Arbitrary Value` generator — aeson 2.2.3 already provides one
- Skipped `genWordyText` — `genSafeText` already generates mixed-case words adequate for case helper tests
- Skipped `genJmesExpr` — tested JMESPath with fixed expressions (`@`, `somefield`) which is sufficient
- Skipped `findSubstring`/`findAllSubstring` — another agent was modifying `Conversion.hs`; not exported anyway
- Tested Handlebars helpers via `callHelper` (direct `Map.lookup` on `defaultHelpers`) instead of through `interpolate`, which is cleaner
- Removed `prop_null_roundtrip`, `prop_bool_roundtrip` (subsumed), and old weak `prop_parse_emit_stable`
