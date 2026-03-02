# Architecture Review: John Ousterhout Lens

_"The most fundamental problem in computer science is problem decomposition: how to take a complex problem and divide it up into pieces that can be solved independently." — A Philosophy of Software Design_

Ousterhout's framework: modules should be **deep** (simple interface hiding significant complexity), not **shallow** (complex interface with thin implementation). Complexity leaks through interfaces. Strategic programming beats tactical.

---

## 1. Module Depth Analysis

### The Deep Modules (Good)

**`Iidy.Yaml.Engine`** — the deepest module in the codebase.

```haskell
preprocessYaml11 :: LoadImportFn -> Map Text OValue -> ByteString -> Text -> IO (Either Text PreprocessResult)
```

One function. Behind it: YAML parsing, YAML 1.1 auto-detection, a two-phase pipeline (IO import loading + pure AST resolution), handlebars interpolation, JMESPath evaluation, custom resource expansion, import cycle detection, variable scoping, and the `OValue` emitter. Hundreds of lines of machinery hidden behind a 4-parameter function. This is deep.

**`Iidy.Yaml.Resolution.Resolver`** — pure recursive descent over a 12-variant AST.

```haskell
resolveAst :: TagContext -> YamlAst -> Either ResolveError OValue
```

Two inputs, one output. Hides: 20+ preprocessing tags (`!$if`, `!$map`, `!$let`, `!$concat`, `!$merge`, `!$expand`, etc.), CloudFormation tag validation, handlebars template interpolation, JMESPath queries, custom resource expansion, variable lookup, type coercion. Deep.

**`Iidy.Yaml.Handlebars.Engine`** — pure template engine.

```haskell
interpolate :: Map Text HelperFn -> Value -> Text -> Either InterpolateError Text
```

Hides: tokenizer, parser, block helpers, helper dispatch, context resolution, partial evaluation, error reporting. All pure. Deep.

**`Iidy.Yaml.JMESPath`** — pure query evaluator.

```haskell
applyJmesPath :: Text -> Value -> Either JMESPathError Value
```

Hides: lexer, parser, 15+ expression types, multi-select, flatten, filter, function evaluation. ~600 LOC behind a 2-parameter function. Deep.

### The Shallow Modules (Problematic)

**`Iidy.Cfn.Context`** — 171 lines, exports its constructor and all fields.

The "interface" of `CfnContext` is the record itself. Every consumer pattern-matches on `cfnEnv ctx`, `cfnStartTime ctx`, etc. There's no information hiding. The module provides `createContext`, `ctxElapsedSeconds`, `ctxDeriveToken`, and `ctxGetUsedTokens` — but consumers routinely reach past these into the record directly. The abstraction is a see-through wall.

**`Iidy.Cfn.Status`** — a module whose entire purpose is classifying status strings. Shallow by nature — it's a lookup table. This is fine; not every module needs to be deep. But it highlights that the real complexity (status _transitions_) isn't captured anywhere.

**The individual `Iidy.Cfn.Operations.*` modules** — each is ~60-120 lines following the same pattern: build request, send, poll, collect, return. They're shallow wrappers around `StackOperations` + `RequestBuilder` + amazonka. The real logic lives in the modules they call. But this is reasonable — they're orchestration, not abstraction.

---

## 2. Information Leakage (PARTIALLY ADDRESSED)

### CfnContext: No Encapsulation

`CfnContext(..)` is exported with all field accessors. 20+ modules import it and reach directly into `cfnEnv ctx` to call `Amazonka.send`. The "context" is just a struct being passed around — there's no behavioral abstraction. If you wanted to mock AWS calls for integration testing, you'd have to modify every call site.

Compare: `pollForCompletionWith` takes `IO [CF.StackEvent]` — the _one_ place where DI is done properly. This function can be tested with `IORef`-backed mocks. Every other AWS interaction is a direct `Amazonka.send (cfnEnv ctx) req` with no seam.

### StackArgs: Implementation Leaks Into Every Consumer

`StackArgs(..)` exports all 21 fields. `RequestBuilder` reaches in to read `saCapabilities`, `saTags`, `saParameters`. `CreateStack` reads `saTemplate`. `DeleteStack` reads `saStackName`. Nobody validates that the fields relevant to their operation are present — they just use `fromMaybe` and hope.

The information that should be hidden: which fields are relevant to which operation. Instead, every operation sees everything and ignores what it doesn't need.

### StackArgsLoader Internals Exposed for Testing

```haskell
module Iidy.Cfn.StackArgsLoader
  ( loadStackArgs
  , LoadedStackArgs(..)
  -- * Internal (exported for testing)
  , getStrMapValidated
  , resolveEnvMaps
  ) where
```

The comment says it: internals exported for testing. This is a classic sign that the module boundary is in the wrong place. The functions that need testing should be in a pure module with a natural public API, not leaked out of an IO module with a comment.

---

## 3. Pass-Through Complexity

Ousterhout identifies _pass-through methods_ as a red flag — functions that exist mainly to forward arguments.

### The `emit` Callback Chain

```
Main.runCfnWithArgs
  └─ passes emit to: action (e.g., createStack)
       └─ passes emit to: emitStackDefinition
       └─ constructs PollConfig with emit baked into callbacks
            └─ pcOnNewEvents = \events -> emit (OdNewStackEvents ...)
            └─ pcOnOperationComplete = \info -> emit (OdOperationComplete ...)
       └─ passes emit to: collectStackContents (which doesn't use it)
```

The `emit` callback is threaded through 3-4 layers to reach the `PollConfig` callbacks where it's actually used. Every intermediate function must accept `(OutputData -> IO ())` as a parameter even though many of them are just forwarding it. `collectStackContents` takes `emit` in some call sites but not others.

### The `argsfilePath` Thread

```
Main.runCfnWithArgs(argsfile)
  └─ action ctx sa' (Just argsfilePath) env emit
       └─ createStack ctx args argsfilePath env emit
            └─ buildCreateStackRequest ctx args True argsfilePath env
                 └─ loadCfnTemplate ctx (saTemplate args) argsfilePath
```

`argsfilePath` passes through 3 functions to reach `loadCfnTemplate` where it's used for resolving relative template paths. Three layers of pass-through for a single `FilePath`.

### The `env` (Environment Name) Thread

Every stack operation takes `env :: Text` (the environment name like "dev" or "prod") and passes it through to... mostly nowhere. It's used in metadata and in the `$envValues` injection during args loading. But the operations receive it as a raw parameter and carry it uselessly.

---

## 4. Tactical vs Strategic Design (PARTIALLY ADDRESSED)

### Strategic: The Output Pipeline

The `OutputData` sum type + `OutputDispatch` + per-variant renderers is _strategic_ design. It anticipates future output modes (JSON was added alongside Interactive), enforces exhaustive handling of all output types, and cleanly separates "what happened" from "how to display it." The 27-variant sum type is wide, but it's a deliberate design investment.

### Strategic: The Two-Phase YAML Engine

Separating import loading (IO) from AST resolution (pure) was a strategic choice. It means the resolver can be tested purely, and the IO surface is limited to the import dispatch. This probably prevented dozens of bugs.

### Tactical: runCfnWithArgs

```haskell
runCfnWithArgs cli operation argsfile stackNameOverride action = do
  let env = goEnvironment (cliGlobalOpts cli)
  ...
  result <- loadStackArgs argsfilePath env operation cliAws
  case result of
    Left err -> dieTxt err
    Right (LoadedStackArgs sa mergedAws detectionCtx) -> do
      (awsEnv, credStack) <- createAwsEnv detectionCtx mergedAws
      sa'' <- applyGlobalConfiguration awsEnv sa
      ...
      ctx <- createContextFromEnv awsEnv credStack operation tp token
      if emitsCommandMetadata operation then ... else pure ()
      rc <- action ctx sa' (Just argsfilePath) env emit
        `finally` cleanupOutputDispatch dispatch
      if emitsCommandMetadata operation then ... else pure ()
      exitCode rc
```

This is a tactical accumulation of steps. Each line was added because the next feature needed it. There's no abstraction — it's a script. The `if emitsCommandMetadata` check appears twice (before and after the action) because metadata and summary are conceptually paired but the code doesn't express this pairing.

A strategic design would extract `CfnOperationRunner` or similar — a pipeline that configures, executes, and wraps operations uniformly. Instead, each concern was stitched in sequentially.

### Tactical: Error Handling

Five error handling patterns (see Hickey review) is the hallmark of tactical programming — each module picked whatever was convenient at the time. `Either Text` is the strategic pattern. `fail`, `catch + stderr`, and silent `SomeException` swallowing are tactical shortcuts.

---

## 5. Complexity Budget

Where is the complexity budget spent?

| Area                     | LOC (approx) | Complexity justification                        |
|--------------------------|-------------:|--------------------------------------------------|
| YAML resolver            |        ~800  | Core business logic. Justified.                   |
| Output renderers         |        ~900  | 27 variants x 2 renderers. Justified by feature.  |
| Operations (14 modules)  |       ~1400  | 14 CFN commands. Thin orchestration. OK.           |
| Import loaders (10)      |        ~600  | 10 URI schemes. Each simple. Justified.            |
| Handlebars engine        |        ~400  | Custom template engine. Justified (no pkg fit).    |
| JMESPath evaluator       |        ~600  | Custom query language. Justified (no pkg fit).     |
| Error display pipeline   |        ~500  | 4 modules for error enhancement. Justified.        |
| StackArgsLoader          |        ~300  | YAML -> domain type. Could be simpler (see below). |
| CLI parser               |        ~600  | optparse-applicative boilerplate. Unavoidable.     |
| Output Types             |        ~460  | 27 record types. Mostly boilerplate.               |
| Main.hs dispatch         |        ~400  | Flat case statement. Clear but long.               |

The complexity is _mostly_ in the right places. The YAML engine and resolver carry the weight because that's where the hard problem is. The output pipeline is wide but intentional.

The complexity that's in the _wrong_ place: `StackArgsLoader` doing business logic through aeson `Value` manipulation instead of domain types. `Main.hs` doing 400 lines of flat dispatch instead of abstracting common patterns.

---

## 6. Interface Design Smells (PARTIALLY ADDRESSED)

### Mixed Abstraction Levels in Function Signatures

```haskell
createStack :: CfnContext -> StackArgs -> Maybe FilePath -> Text -> (OutputData -> IO ()) -> IO (Either Text Int)
```

Five parameters at four different abstraction levels:
1. `CfnContext` — AWS execution context (infrastructure)
2. `StackArgs` — domain configuration (application)
3. `Maybe FilePath` — file system detail (implementation)
4. `Text` — environment name (configuration)
5. `(OutputData -> IO ())` — output callback (presentation)

A deep interface would take 1-2 parameters. This takes 5 from 4 layers. Every call site must assemble all 5.

### Defaults That Should Be In Types

`emptyStackArgs` has 21 `Nothing` fields. Callers override specific fields for specific operations. But the record doesn't guide you — there's no type-level distinction between "this field is optional for this operation" and "this field is irrelevant to this operation."

---

## 7. What Would Strategic Redesign Look Like? (PARTIALLY ADDRESSED)

1. **AWS abstraction layer.** A `CfnClient` module that wraps `Amazonka.send`/`Amazonka.paginate` behind an interface. Today you'd need to modify 20+ modules to change the AWS calling convention. With a client module, you'd change one.

2. **Operation-specific argument types.** Instead of all operations taking `StackArgs`, `createStack` takes `CreateStackConfig` (with non-optional `stackName` and `template`), `deleteStack` takes `DeleteStackConfig` (with non-optional `stackName`). The generic `StackArgs` stays as the deserialization target; conversion to specific types is where validation happens.

3. **Error algebra.** One sum type for all errors. `data IidyError = AwsError AwsErrorInfo | ParseError ParseErrorInfo | ValidationError Text | ...`. Uniform handling throughout.

4. **Operation pipeline abstraction.** A combinator that wraps the common create-dispatch-load-args-create-context-emit-metadata-run-emit-summary pattern, eliminating the tactical `runCfnWithArgs`.

---

## Verdict

The codebase has **strong strategic bones** in the YAML pipeline and output architecture. The pure core (resolver, handlebars, JMESPath, schema validator) is genuinely deep — simple interfaces hiding real complexity. The import dispatch via function injection is a good design choice.

The tactical debt is concentrated at the **boundaries**: Main.hs dispatch, CfnContext, StackArgs, error handling, and the `emit` callback threading. These are the places where "make it work for this operation" accumulated into "pass everything everywhere."

Ousterhout would say: the problem isn't that the code is wrong — it's that the interfaces carry too much information. Narrower interfaces at the operation boundary would make the deep modules even deeper and the shallow wiring even thinner.

---

## Post-Review Status Updates (Session 46, 2026-03-02)

_These annotations were added after the review to track which findings have been addressed._

Ousterhout's review focuses on module depth, information leakage, and interface design. Most findings are structural concerns about the CFN boundary layer. The session 45-46 fixes address some specific type-safety issues but not the broader architectural patterns.

| #  | Finding                                                         | Status              | Notes                                                                                                             |
|----|-----------------------------------------------------------------|---------------------|-------------------------------------------------------------------------------------------------------------------|
| 1a | Shallow module: CfnContext (exports everything, no hiding)      | OPEN                | CfnContext still exports all fields. No encapsulation change.                                                     |
| 1b | Shallow module: CfnStatus (lookup table, no transitions)        | OPEN                | Status still Text-based. No state machine encoding.                                                               |
| 2a | Information leakage: CfnContext(..) exports all fields          | OPEN                | No change to CfnContext export list or abstraction boundary.                                                      |
| 2b | Information leakage: StackArgs(..) — all 21 fields exposed      | PARTIALLY ADDRESSED | `saOnFailure` now `Maybe OnFailure` (ADT) and `saCapabilities` now `Maybe [Capability]` (ADT) — these parse at the YAML boundary with clear errors. But StackArgs still exports all fields; per-operation config types not introduced. |
| 2c | Information leakage: StackArgsLoader internals exported for test | OPEN                | Still exports `getStrMapValidated` and `resolveEnvMaps` as testing internals.                                     |
| 3a | Pass-through: emit callback threaded through 3-4 layers         | OPEN                | Emit callback threading unchanged. No operation pipeline abstraction.                                             |
| 3b | Pass-through: argsfilePath threaded through 3 functions          | OPEN                | argsfilePath pass-through unchanged.                                                                              |
| 3c | Pass-through: env (environment name) carried uselessly           | OPEN                | env parameter threading unchanged.                                                                                |
| 4a | Tactical: runCfnWithArgs is scripted accumulation                | OPEN                | runCfnWithArgs not refactored. No CfnOperationRunner abstraction.                                                |
| 4b | Tactical: error handling — 5 patterns, no unified algebra        | PARTIALLY ADDRESSED | TemplateLoader converted from `fail` to `Either Text` (6 sites). This removes one of the 5 error patterns. Broader `IidyError` sum type not introduced. |
| 5  | Complexity budget: StackArgsLoader doing logic via aeson Value   | OPEN                | StackArgsLoader still manipulates aeson Value directly.                                                           |
| 6a | Interface smell: createStack takes 5 params at 4 abstraction levels | OPEN             | Function signatures unchanged. No parameter consolidation.                                                        |
| 6b | Interface smell: emptyStackArgs with 21 Nothing fields           | PARTIALLY ADDRESSED | Two fields now use ADTs instead of Text (OnFailure, Capability), providing type-level guidance. But still 21 Maybe fields with no per-operation distinction. |
| 7  | Strategic redesign: operation-specific argument types             | PARTIALLY ADDRESSED | OnFailure ADT and Capability ADT are the first steps toward per-operation types with validated fields. Full CreateStackConfig / DeleteStackConfig not yet introduced. |
