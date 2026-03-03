# Architectural Refactoring Plan

Synthesized from six architecture reviews (Hickey, Ousterhout, Minsky, Krishnamurthi, Kmett, Muratori).
Ordered by impact-to-effort ratio. Each phase produces green commits (tests pass, zero warnings).

---

## Exclusions

The following are explicitly **out of scope**:

- **Monad stack changes**: No `ExceptT`, `ReaderT`, `MonadError`, MTL. The plain IO + explicit
  parameter passing style stays. Changing it would break differential testing and touch every
  module.
- **Free monads / effect systems**: No `Free CfnF`, no `freer-simple`, no `polysemy`. Same
  reasoning as above.
- **Recursion schemes**: No `Fix OValueF`, no `recursion-schemes` dependency. The manual
  pattern matching is clearer for this codebase.
- **Optics on custom types**: No `lens` or `optics` dependency for `OValue` traversals. The
  codebase already depends on `microlens` for amazonka; adding prisms/traversals for `OValue`
  would be a heavy lift with unclear payoff.
- **Typeclasses for import loaders**: The `LoadImportFn` function injection works. Adding an
  `ImportLoader` typeclass with associated types would add complexity without solving a real
  problem.
- **Module merging** (Muratori's suggestion): Folding 11 tiny modules into neighbors would
  create large diffs for marginal value. Not worth the churn.
- **Anything that changes snapshot output**: Every change must preserve existing render snapshot
  and error snapshot compatibility with Rust. Run `scripts/snapshot-compare.sh` and
  `scripts/error-snapshot-compare.sh` after any phase that touches the resolver, emitter, or
  error display.

---

## Phase 1: Stringly-Typed Enums (Mechanical, Low Risk)

**Problem**: `OnFailure`, `Capability`, and `OutputFormat` are `Text` values compared as raw
strings deep in execution. Typos are silent bugs. (Hickey #2, Minsky #1/#9, Kmett #8)

### 1.1 — OnFailure enum

**What changes**:
- `Iidy.Cfn.Types`: Add `data OnFailure = DoNothing | Rollback | Delete` with `Show`, `Eq`.
  Add `onFailureToText :: OnFailure -> Text` and `parseOnFailure :: Text -> Either Text OnFailure`.
- `Iidy.Cfn.Types`: Change `saOnFailure :: !(Maybe Text)` to `saOnFailure :: !(Maybe OnFailure)`.
- `Iidy.Cfn.RequestBuilder`: Replace `mapOnFailure :: Maybe Text -> Maybe CF.OnFailure` with
  a direct mapping from our `OnFailure` to amazonka's `CF.OnFailure`. Remove the string-matching
  `case` and the silent `_ -> Nothing` fallback.
- `Iidy.Cfn.StackArgsLoader`: Parse `OnFailure` from the YAML `Value` using `parseOnFailure`,
  returning `Left` on invalid values instead of silently passing through.
- `Iidy.InitStackArgs`: Update the comment template (cosmetic only).

**Why**: Eliminates silent fallback on `saOnFailure = Just "BANANA"`. Moves validation to the
parse boundary. (Minsky #9, Hickey #2)

**Risk**: Low. Three files touched. Validation moves earlier, which could surface errors that
were previously swallowed silently — but that is correct behavior.

**Files touched**: 3-4 (`Types.hs`, `RequestBuilder.hs`, `StackArgsLoader.hs`, `InitStackArgs.hs`)

**Keeping it green**: Run `cabal test`. The `StackArgsLoader` tests and `RequestBuilder` tests
cover this path. Add a test for `parseOnFailure` round-trip and rejection of invalid values.

### 1.2 — Capability enum

**What changes**:
- `Iidy.Cfn.Types`: Add `data Capability = CapIAM | CapNamedIAM | CapAutoExpand` with `Show`, `Eq`.
  Add `parseCapability :: Text -> Either Text Capability` and
  `capabilityToText :: Capability -> Text`.
- `Iidy.Cfn.Types`: Change `saCapabilities :: !(Maybe [Text])` to
  `saCapabilities :: !(Maybe [Capability])`.
- `Iidy.Cfn.RequestBuilder`: Replace `mapCapability :: Text -> Maybe CF.Capability` with
  direct mapping from our `Capability`. Remove the silent `_ -> Nothing` fallback (line 155-156).
- `Iidy.Cfn.StackArgsLoader`: Parse capabilities from YAML, returning `Left` on unknown values.

**Why**: Same rationale as 1.1. `saCapabilities = Just ["CAPABILITY_IAn"]` (typo) is currently
silently dropped. (Minsky #1, Hickey #2)

**Risk**: Low. Same files as 1.1.

**Files touched**: 3-4

**Keeping it green**: Same as 1.1. Add test for `parseCapability` with valid and invalid inputs.

### 1.3 — OutputFormat enum

**What changes**:
- `Iidy.Types`: Add `data OutputFormat = FormatJson | FormatYaml | FormatCfnYaml` with
  `Show`, `Eq`. Add `parseOutputFormat :: Text -> Either Text OutputFormat`.
- `Iidy.Cli`: Change `raFormat :: !Text` to `raFormat :: !OutputFormat` in `RenderArgs`.
  Change `giaFormat :: !Text` to `giaFormat :: !OutputFormat` in `GetImportArgs`.
- `Iidy.Cli.Parser`: Parse the format flag using `parseOutputFormat` at the CLI boundary.
  Reject unknown formats with a clear error.
- `Iidy.Render`: Replace `case T.toLower (raFormat args) of "json" -> ...` with
  `case raFormat args of FormatJson -> ...`. Remove the `_ -> emitYaml result` wildcard.
- `Iidy.GetImport`: Same pattern as `Render`.

**Why**: Eliminates the `_ -> emitYaml result` silent default on typos. The user gets an
error at CLI parse time instead of silently getting YAML when they typed `"josn"`. (Minsky #9)

**Risk**: Low. Four files. CLI parse error for invalid format is user-visible but correct.

**Files touched**: 4-5

**Keeping it green**: Run `cabal test`. Add unit test for `parseOutputFormat` with valid
inputs and one invalid input. Existing render tests should pass unchanged since they use
valid format strings.

---

## Phase 2: Stack Status Type (Medium Impact, Low Risk)

**Problem**: Stack statuses are `Text` everywhere. The compiler cannot catch typos in status
strings, and the state machine is implicit in scattered `elem` checks. Amazonka already has
`StackStatus` as a sum type, but it is converted to `Text` at the boundary and discarded.
(Hickey #7, Minsky #2, Kmett #8)

### 2.1 — Introduce StackStatus type

**What changes**:
- `Iidy.Cfn.Types`: Add a `StackStatus` sum type with all 18+ variants matching
  CloudFormation's actual status values. Add `stackStatusToText :: StackStatus -> Text` and
  `parseStackStatus :: Text -> Maybe StackStatus`. Include a catch-all `UnknownStatus !Text`
  constructor for forward compatibility (new statuses that AWS adds).
- `Iidy.Cfn.Status`: Rewrite `isTerminalStackStatus`, `isTerminalResourceStatus`,
  `isFailureStatus`, `isSuccessStatus`, `isInProgressStatus`, `isRollbackStatus` to pattern
  match on `StackStatus` instead of string operations (`isSuffixOf "_FAILED"`, etc.).
- `Iidy.Cfn.Context`: Change `allTerminalStatuses :: [Text]` and friends to
  `allTerminalStatuses :: [StackStatus]`. The usage sites compare with `elem`, which works
  the same on the enum.

**Why**: Makes status handling exhaustive and compiler-verified. A new status variant triggers
pattern match warnings everywhere it needs handling. (Minsky #2, Hickey #7)

**Risk**: Low-medium. The type is internal (not serialized to YAML or used in snapshots).
The `Text` rendering for display stays identical. The `parseStackStatus` function at the
amazonka boundary is the only new conversion point.

**Files touched**: 3 (`Types.hs`, `Status.hs`, `Context.hs`)

**Keeping it green**: All existing status logic is tested via polling tests and status
classification tests. The behavior is identical; only the representation changes. Run
`cabal test`.

### 2.2 — Thread StackStatus through output types

**What changes**:
- `Iidy.Output.Types`: Change `sdStatus :: !Text` (in `StackDefinition`),
  `seResourceStatus :: !Text` (in `StackEvent`), `ssiStatus :: !Text` (in `StackStatusInfo`),
  `sleStackStatus :: !Text` (in `StackListEntry`), `sriResourceStatus :: !Text` (in
  `StackResourceInfo`), and `csiStatus :: !Text` (in `ChangeSetInfo`) to use `StackStatus`.
- `Iidy.Output.Renderers.Interactive.Sections`: Use `stackStatusToText` when rendering status
  values to display text.
- `Iidy.Output.Renderers.Json`: Use `stackStatusToText` when converting to JSON values.
- `Iidy.Output.Status`: Update `categorizeStatus` to pattern match on `StackStatus`.
- All `Iidy.Cfn.Operations.*` modules that construct output records: Use `parseStackStatus`
  when extracting status from amazonka responses, store as `StackStatus`.

**Why**: Completes the type safety chain from AWS response through to output. No status
string comparisons remain in the hot path. (Minsky #2)

**Risk**: Medium. Touches many files but each change is mechanical (wrap in `parseStackStatus`
at input, unwrap with `stackStatusToText` at output). Output text is identical.

**Files touched**: ~12-15

**Keeping it green**: Run `cabal test` and `scripts/snapshot-compare.sh`. The rendered output
must be identical since `stackStatusToText` produces the same strings. The integration test
builders need updating to use `StackStatus` constructors instead of `Text` literals.

---

## Phase 3: TemplateLoader Error Handling (Low Effort, Medium Impact)

**Problem**: `Iidy.Cfn.TemplateLoader` uses `fail` (lines 76, 83, 97, 106, 168, 175) which
throws `IOError`s that propagate to the top-level catch in `Main.hs`. This is inconsistent
with the `Either Text` pattern used everywhere else. Callers cannot distinguish template
loader errors from other IO errors. (Hickey #3, Ousterhout #4, Minsky #6)

### 3.1 — Convert TemplateLoader from fail to Either

**What changes**:
- `Iidy.Cfn.TemplateLoader`: Change `loadCfnTemplate` return type from `IO TemplateResult` to
  `IO (Either Text TemplateResult)`. Replace all `fail` calls with `pure (Left ...)`.
  Replace `loadFileContent` from using `fail` to returning `Either Text Text`.
  Replace `checkTemplateSize` from using `fail` to returning `Either Text ()`.
- All callers of `loadCfnTemplate` (in `RequestBuilder.hs` and the operations that call it):
  Handle the `Left` case by propagating the error through the existing `Either Text` return.

**Why**: Eliminates the `fail` pattern. Template loading errors now compose with the `Either Text`
pattern used by everything else. The caller can distinguish "template too large" from
"file not found" from "parse error" without catching exceptions. (Hickey #3)

**Risk**: Low. The `fail` calls are well-defined error paths. Converting to `Either` makes them
explicit. The `try` in `Main.hs` still catches unexpected exceptions; these are no longer among
them.

**Files touched**: 2-3 (`TemplateLoader.hs`, `RequestBuilder.hs`, possibly one operations module)

**Keeping it green**: Run `cabal test`. The TemplateLoader is covered by render snapshot tests
(the `render:` prefix path). Add a unit test that confirms a missing template returns `Left`
rather than throwing.

---

## Phase 4: CfnContext Separation (Medium Effort, Medium Impact)

**Problem**: `CfnContext` mixes 7 concerns. Read-only operations receive mutable token state
they never use. Display-only fields (`cfnCredentialSources`, `cfnOperation`) are smuggled into
the execution context. (Hickey #1, Ousterhout #1, Minsky #4)

### 4.1 — Extract display-only fields from CfnContext

**What changes**:
- `Iidy.Cfn.Context`: Remove `cfnCredentialSources :: !CredentialSourceStack` and
  `cfnOperation :: !CfnOperation` from `CfnContext`. These are only used in
  `Main.hs` when constructing `CommandMetadata`.
- `Main.hs`: Pass `CredentialSourceStack` and `CfnOperation` directly to the
  `constructCommandMetadata` call, instead of extracting them from `ctx`.
- `Iidy.Cfn.CommandMetadata`: Update `constructCommandMetadata` signature to take
  `CredentialSourceStack` and `CfnOperation` as explicit parameters instead of
  extracting from `CfnContext`.
- `createContext` and `createContextFromEnv`: Remove the `CfnOperation` and
  `CredentialSourceStack` parameters. Simplify the signature.

**Why**: CfnContext now holds only execution-relevant state (AWS env, timing, tokens).
Display metadata flows separately. The context no longer carries information used at exactly
one call site. (Hickey #1, Ousterhout #2)

**Risk**: Low-medium. `cfnOperation` is used in exactly one place (`cfnOperationStr`).
`cfnCredentialSources` is used in exactly one place (CommandMetadata). Both are easy to
extract. The risk is missing a use site, caught by the compiler.

**Files touched**: 3-4 (`Context.hs`, `Main.hs`, `CommandMetadata.hs`, possibly `createContext` callers)

**Keeping it green**: Run `cabal test`. The CommandMetadata integration tests verify the
output format. The display must be identical.

### 4.2 — Separate token tracking from read-only context (optional)

**What changes**:
- `Iidy.Cfn.Context`: Split into `CfnReadContext` (env, startTime, timeProvider) and
  `CfnWriteContext` (readContext + primaryToken + usedTokens IORef).
- Read-only operations (`describeStack`, `listStacks`, etc.): Take `CfnReadContext`.
- Write operations (`createStack`, `updateStack`, etc.): Take `CfnWriteContext`.

**Why**: Makes it a type error to pass mutable token state to read-only operations.
(Minsky #4)

**Risk**: Medium. Touches all operation modules (~14) to update the context parameter type.
Each change is mechanical but the scope is wide.

**Files touched**: ~16 (Context.hs + all operations + Main.hs)

**Keeping it green**: Compiler-driven. Change the type, fix every call site the compiler
flags. Run `cabal test`.

**Note**: Phase 4.2 is optional and can be deferred. Phase 4.1 alone delivers most of the
value with much lower effort.

---

## Phase 5: OdRawOutput Refinement (Low Effort, Low-Medium Impact)

**Problem**: `OdRawOutput !Text` is an unstructured escape hatch in a 27-variant structured
output pipeline. The JSON renderer wraps it in `{"type": "raw_output", "data": "..."}`,
losing all structure. It is used by exactly 3 commands: Render, GetImport, and param operations.
(Hickey #5, Minsky #3)

### 5.1 — Replace OdRawOutput with command-specific variants

**What changes**:
- `Iidy.Output.Types`: Add `OdRenderOutput !RenderOutput` and `OdGetImportOutput !GetImportOutput`
  data constructors.  Add supporting record types:
  ```
  data RenderOutput = RenderOutput { roContent :: !Text, roFormat :: !OutputFormat }
  data GetImportOutput = GetImportOutput { gioContent :: !Text, gioFormat :: !OutputFormat }
  ```
  Keep `OdRawOutput` temporarily for any remaining uses (param commands).
- `Iidy.Render`: Emit `OdRenderOutput` instead of `OdRawOutput`.
- `Iidy.GetImport`: Emit `OdGetImportOutput` instead of `OdRawOutput`.
- `Iidy.Output.Renderers.Interactive.Sections`: Add cases for new constructors (both just print
  the content text, identical behavior to current `OdRawOutput`).
- `Iidy.Output.Renderers.Json`: Add cases for new constructors, emitting structured JSON with
  format information (`{"type": "render_output", "format": "yaml", "data": "..."}`).

**Why**: The JSON renderer now knows whether the output is a rendered template or an imported
value, and what format it is in. The interactive renderer behavior is unchanged. (Minsky #3)

**Risk**: Low. Additive change (new constructors). Existing `OdRawOutput` handling remains
for param commands. No snapshot impact.

**Files touched**: 5 (`Output/Types.hs`, `Render.hs`, `GetImport.hs`, `Sections.hs`, `Json.hs`)

**Keeping it green**: Run `cabal test`. Add integration test builders for the new output types.
Interactive rendering is text-identical to current behavior.

---

## Phase 6: Krishnamurthi Testing Recommendations (SUBSTANTIALLY ADDRESSED)

_PLT Redex formal semantics (2026-03-02/03, Sessions 12-14 + 2026-03-03--1) addresses findings #1-4, #6, #8, #10._
_See `notes/handoffs/2026-03-02-plt-redex-formal-semantics.md` and `spec/` directory (388 tests)._

**Problem**: The test suite is implementation-tested, not specification-tested. It verifies
specific inputs produce correct outputs but does not verify the algebraic properties that
users rely on. The JMESPath subset is undocumented. Error message content is tested only by
out-of-band snapshot scripts. (Krishnamurthi #2, #6, #8, #9)

### 6.1 — Semantic property tests for preprocessing tags

**What changes**:
- `test/Iidy/Yaml/Resolution/PropertyTests.hs` (new file): Add property tests for:
  - **`!$merge` right-bias**: For any two objects `a` and `b`, `merge([a, b])` has `b`'s keys
    overriding `a`'s. Property: for all keys in `b`, `lookup key (merge [a, b]) == lookup key b`.
  - **`!$merge` identity**: `merge([a, {}]) == a` and `merge([{}, a]) == a`.
  - **`!$map` preserves length**: `length(map(f, xs)) == length(xs)`.
  - **`!$concat` associativity**: `concat([concat([a,b]),c])` produces the same elements as
    `concat([a,concat([b,c])])`.
  - **`!$let` scoping**: Inner bindings shadow outer ones. `let x=1 in (let x=2 in x)` == 2.
  - **`!$if` strictness**: Only the selected branch is evaluated (test by putting a
    variable-not-found error in the unselected branch and verifying no error).
  - **Resolution idempotency**: Resolving a fully-resolved document again produces the same
    result.
  - **CloudFormation tag pass-through**: Tags without `!$` prefixes (`!Ref`, `!Sub`, etc.)
    pass through resolution unchanged.

**Why**: These are the semantic laws that users implicitly rely on. If any property breaks,
it is a real bug. (Krishnamurthi #6)

**Risk**: Low. Additive (new test file). No code changes. May discover existing bugs, which
would need fixing before the commit is green.

**Files touched**: 1 new test file + `test/Main.hs` (or test module registration)

**Keeping it green**: Run `cabal test`. If a property test fails, it has found a real bug
that should be investigated and fixed before committing.

### 6.2 — JMESPath subset documentation

**What changes**:
- `notes/jmespath-subset.md` (new file): Document which JMESPath features are implemented
  and which are not. Include:
  - Supported expression forms (field, sub-expression, index, flatten, filter, multi-select
    hash, multi-select list, pipe, or, and, not, comparisons, wildcard, literal, raw string).
  - **Not supported**: Built-in functions (all 30+), object wildcard (`.*`), slice expressions
    (`[0:5]`).
  - Clear statement that this is a subset and link to the full spec.
- `DIVERGENCES.md`: Add a section documenting the JMESPath subset divergence.
- `Iidy.Yaml.JMESPath`: Improve the parser error message for unsupported features. When
  parsing encounters `(` (function call), emit an error like "JMESPath functions are not
  supported. Expression: length(@)". When encountering `[n:m]` (slice), emit "JMESPath
  slice expressions are not supported."

**Why**: Users reading jmespath.org will write expressions that fail silently or with
unhelpful parse errors. Documenting the subset and improving errors prevents confusion.
(Krishnamurthi #8)

**Risk**: Low. Documentation is additive. Parser error improvement is a small change to the
lexer/parser error paths. No output changes for valid expressions.

**Files touched**: 2-3 (`JMESPath.hs`, `DIVERGENCES.md`, new doc file)

**Keeping it green**: Run `cabal test`. Add a test that verifies the improved error message
for `length(@)` and `[0:5]`.

### 6.3 — Error message content tests in cabal test

**What changes**:
- `test/Iidy/Yaml/Errors/SnapshotTests.hs` (new file): For each of the 49 error snapshot
  fixtures, add a test that:
  1. Runs the preprocessing pipeline on the fixture input.
  2. Extracts the error.
  3. Asserts key content of the error message (error code, key phrase, file/line reference).
  These are NOT full snapshot comparisons (those stay in the external script). These are
  content assertions: "error contains ERR_2001", "error mentions variable 'foo'",
  "error mentions line 42".

**Why**: Error message regressions are currently only caught by the external snapshot script,
not by `cabal test`. Moving key assertions into the test suite means CI catches regressions
automatically. (Krishnamurthi #9)

**Risk**: Low. Additive test file. Content assertions are looser than snapshot comparisons,
so they are robust to minor formatting changes. The full snapshot comparison script remains
as the strict check.

**Files touched**: 1 new test file + test module registration

**Keeping it green**: Run `cabal test`. All 49 assertions must pass.

---

## Phase 7: StackArgsLoader Internal Cleanup (Medium Effort, Medium Impact)

**Problem**: `StackArgsLoader` exports internal functions "for testing" and does all business
logic via aeson `Value` manipulation (pattern matching on `Object`, `String`, `Array`). The
serialization format is the intermediate representation. (Hickey #6, Ousterhout #2/#3)

### 7.1 — Extract pure validation functions to a separate module

**What changes**:
- `Iidy.Cfn.StackArgs.Validation` (new module): Move `getStrMapValidated`,
  `resolveEnvMaps`, and `valueToStackArgs` (the pure `Value -> Either Text StackArgs`
  conversion) into this module with a proper public API. These functions are pure
  (`Value -> Either Text _`) and testable without IO.
- `Iidy.Cfn.StackArgsLoader`: Remove the `-- * Internal (exported for testing)` comment
  and the internal exports. Import from `StackArgs.Validation` instead.
- Tests: Update imports to use the new module.

**Why**: The "exported for testing" comment is a sign the module boundary is wrong. The pure
functions deserve their own module with a natural public API. (Ousterhout #2)

**Risk**: Low. Module extraction with import changes only. No logic changes.

**Files touched**: 3-4 (new module, `StackArgsLoader.hs`, test files)

**Keeping it green**: Run `cabal test`. All existing StackArgsLoader tests pass unchanged.

### 7.2 — Validate StackArgs field interactions

**What changes**:
- `Iidy.Cfn.StackArgs.Validation`: Add `validateStackArgs :: CfnOperation -> StackArgs -> Either Text StackArgs`
  that checks for contradictory field combinations:
  - `saDisableRollback = Just True` with `saOnFailure = Just Rollback` -> error
  - `saUsePreviousTemplate = Just True` with `saTemplate = Just _` -> warning or error
  - Missing `saStackName` for operations that require it -> early error with clear message
  - Missing `saTemplate` for create-stack -> early error
- `Main.hs` (or the `runCfnWithArgs` site): Call `validateStackArgs` after loading, before
  executing the operation.

**Why**: Currently, contradictory field combinations are silently accepted and one field
wins arbitrarily. Validating at the boundary catches user mistakes early. (Minsky #1, Hickey #2)

**Risk**: Low-medium. Could surface errors for configs that previously "worked" by luck.
The validation should match Rust's behavior (check what Rust does with contradictory fields
before implementing).

**Files touched**: 2-3

**Keeping it green**: Run `cabal test`. Add tests for each validation rule. Check against
Rust behavior for edge cases.

---

## Phase 8: Emit Callback Documentation + Minor Cleanup (Low Effort, Low Impact)

**Problem**: The `emit` callback is threaded through 3-4 layers. Several modules bypass it
entirely (Sts.hs, Render.hs write directly to stderr). This inconsistency means "all output
goes through the pipeline" is not actually true. (Hickey #5, Ousterhout #3)

### 8.1 — Route Sts.hs warning through emit callback

**What changes**:
- `Iidy.Aws.Sts`: Change `getCallerIdentity` to return the warning as part of its result
  (e.g., `IO (Either Text (CallerIdentity, Maybe Text))` where the `Maybe Text` is a warning
  message) instead of writing directly to stderr.
- The caller in `Main.hs` or `CommandMetadata`: If a warning is returned, emit it through
  the output pipeline as `OdStatusUpdate` with `LevelWarning`.

**Why**: All output should go through the pipeline. Direct stderr writes bypass JSON output
mode and can interleave with structured output. (Hickey #5)

**Risk**: Low. The warning is rare (STS call failure). The change is small.

**Files touched**: 2 (`Sts.hs`, caller in `Main.hs`)

**Keeping it green**: Run `cabal test`. The STS tests use mocks and should pass unchanged.

### 8.2 — Document the emit callback pattern

**What changes**:
- `docs/dev/output-pipeline.md` (if it exists, add a section; if not, create): Document that
  `(OutputData -> IO ())` is the callback pattern, why it is threaded through operation layers,
  and the known exceptions (Render.hs stderr writes are intentional for error display, not
  part of the output pipeline).

**Why**: Future maintainers need to know the pattern and its exceptions. (Ousterhout #3)

**Risk**: None. Documentation only.

**Files touched**: 1

---

## Phase 9: PollConfig Refinement (Low Effort, Low Impact)

**Problem**: `PollConfig` has paired fields where the relationship is implicit. A timeout
value can exist without a handler, and vice versa. (Minsky #5)

### 9.1 — Introduce InactivityPolicy type

**What changes**:
- `Iidy.Cfn.StackOperations` (or a types module): Add:
  ```haskell
  data InactivityPolicy
    = NoInactivityTimeout
    | WithInactivityTimeout !Int (InactivityTimeoutInfo -> IO ())
  ```
- `PollConfig`: Replace `pcInactivityTimeoutSecs :: !(Maybe Int)` and
  `pcOnInactivityTimeout :: InactivityTimeoutInfo -> IO ()` with
  `pcInactivityPolicy :: !InactivityPolicy`.
- All `PollConfig` construction sites: Use `NoInactivityTimeout` or
  `WithInactivityTimeout secs handler` instead of setting two fields independently.
- `pollForCompletionWith`: Pattern match on `InactivityPolicy` instead of checking
  `pcInactivityTimeoutSecs` for `Just`/`Nothing`.

**Why**: Makes it impossible to specify a timeout without a handler or vice versa.
The paired invariant is now structural. (Minsky #5)

**Risk**: Low. The change is internal to the polling module and its callers (the operation
modules). No output changes.

**Files touched**: ~6 (StackOperations + operation modules that construct PollConfig)

**Keeping it green**: Run `cabal test`. The polling mock tests cover this path.

---

## Phase 10: SomeException Narrowing (Medium Effort, Medium Impact)

**Problem**: ~30 call sites use `try @SomeException` which catches everything including
async exceptions. This is a safety hazard (can catch `ThreadKilled`, `StackOverflow`).
It also erases the exception type, making error handling stringly-typed at the exception
level. (Hickey #3, Minsky #6)

### 10.1 — Narrow SomeException catches to specific types

**What changes**:
- Import loaders (`Ssm.hs`, `SsmPath.hs`, `S3.hs`, `Cfn.hs`, `Http.hs`, `Git.hs`): Replace
  `try @SomeException` with `try @Amazonka.Error` or `try @IOException` as appropriate.
  For amazonka calls, catch `Amazonka.Error`. For process calls (`Git.hs`), catch `IOException`.
  For HTTP calls, catch `HttpException`.
- `Iidy.Params.Client`: Replace `try @SomeException` with `try @Amazonka.Error`.
- `Iidy.Cfn.Operations.*`: Replace `try @SomeException` with `try @Amazonka.Error` for
  all amazonka send calls.
- `Iidy.Cfn.GlobalConfig`: Replace `try @SomeException` with `try @Amazonka.Error`.
- `Iidy.Aws.Timing`: The NTP `catch @SomeException` is intentional (network failure should
  fall back silently). Document this with a comment but keep it as-is.

**Why**: Narrowing exception catches prevents swallowing async exceptions and makes the
error handling intention explicit. (Hickey #3)

**Risk**: Medium. If an unexpected exception type was being caught and handled, narrowing
will let it propagate. This is correct behavior but could change failure modes. Test
thoroughly.

**Files touched**: ~12-15

**Keeping it green**: Run `cabal test`. The mock-based tests should pass unchanged since
they don't throw real exceptions. Manual testing with invalid AWS credentials would be
valuable to verify error paths.

---

## Summary: Phase Ordering and Dependencies

```
Phase 1 (Enums)           -- No dependencies. Start here.
  1.1 OnFailure
  1.2 Capability
  1.3 OutputFormat

Phase 2 (StackStatus)     -- No dependency on Phase 1.
  2.1 Introduce type       Can run in parallel with Phase 1.
  2.2 Thread through output

Phase 3 (TemplateLoader)  -- No dependencies.
  3.1 fail -> Either       Can run in parallel with Phases 1-2.

Phase 4 (CfnContext)      -- No dependencies.
  4.1 Extract display      Can run in parallel with Phases 1-3.
  4.2 Read/Write split     Depends on 4.1.

Phase 5 (OdRawOutput)     -- Depends on Phase 1.3 (OutputFormat type).
  5.1 Command-specific variants

Phase 6 (Testing)         -- No dependencies on code phases.
  6.1 Property tests       Can run at any time.
  6.2 JMESPath docs        Can run at any time.
  6.3 Error content tests  Can run at any time.

Phase 7 (StackArgsLoader) -- Depends on Phase 1.1 and 1.2 (enum types in StackArgs).
  7.1 Extract validation
  7.2 Validate interactions

Phase 8 (Emit cleanup)    -- No dependencies.
  8.1 Sts warning          Can run at any time.
  8.2 Documentation        Can run at any time.

Phase 9 (PollConfig)      -- No dependencies.
  9.1 InactivityPolicy     Can run at any time.

Phase 10 (SomeException)  -- No dependencies. Run last (highest risk).
  10.1 Narrow catches
```

### Estimated Total Scope

| Phase | Commits | Files touched | Risk   |
|-------|--------:|--------------:|--------|
| 1     |       3 |          ~12  | Low    |
| 2     |       2 |          ~18  | Low-Med|
| 3     |       1 |           ~3  | Low    |
| 4     |     1-2 |          ~20  | Medium |
| 5     |       1 |           ~5  | Low    |
| 6     |       3 |           ~5  | Low    |
| 7     |       2 |           ~6  | Low-Med|
| 8     |       2 |           ~3  | Low    |
| 9     |       1 |           ~6  | Low    |
| 10    |       1 |          ~15  | Medium |
| **Total** | **~17** | **(unique ~40)** | |

### Cross-Cutting Themes Addressed

| Theme (from all reviewers)                  | Phases       |
|---------------------------------------------|--------------|
| StackArgs 21-Maybe bag                      | 1.1, 1.2, 7  |
| Stack statuses as Text                      | 2            |
| Five error handling patterns                 | 3, 10        |
| CfnContext mixing concerns                  | 4            |
| OdRawOutput escape hatch                    | 5            |
| Stringly-typed enums                        | 1            |
| Testing semantic properties                 | 6            |
| JMESPath subset undocumented                | 6.2          |
| Error message content untested in CI        | 6.3          |
| Emit callback bypass (stderr writes)        | 8            |
| PollConfig paired fields                    | 9            |
| SomeException over-catching                 | 10           |
