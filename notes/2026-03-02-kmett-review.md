# Architecture Review: Edward Kmett Lens

_"The right abstraction makes the impossible trivial and the trivial automatic."_

Kmett's perspective: Haskell's type system and abstraction mechanisms exist to be used. Typeclasses, higher-kinded types, optics, free monads, profunctors — these aren't ivory tower indulgences. They're tools for making the compiler do your work. The question is whether iidy-hs uses the type system to its potential, or whether it's "Haskell as a better Java."

---

## 1. No Typeclasses. Anywhere.

The entire 85-module, 15k+ LOC codebase defines **zero typeclasses** (beyond stock deriving). No `class`, no `instance` (beyond derived `Show`, `Eq`, `Ord`). No `Functor`, no `Foldable`, no `Traversable` on custom types. No `MonadReader`, no `MonadError`, no `Has` pattern.

This is a deliberate architectural choice: plain IO, explicit parameter passing, records of functions for DI. And it works — the code is readable, the types are simple, the module structure is clean.

But Kmett would ask: **what opportunities are you leaving on the table?**

### What Typeclasses Would Buy You

**A `HasCfnEnv` class** would eliminate the pass-through problem:

```haskell
class HasCfnEnv a where
  cfnEnvL :: Lens' a Amazonka.Env

-- Now any function that needs AWS can be polymorphic:
sendAws :: (HasCfnEnv ctx, MonadIO m) => ctx -> Amazonka.AWSRequest a => a -> m (Amazonka.AWSResponse a)
sendAws ctx req = liftIO $ runResourceT $ Amazonka.send (view cfnEnvL ctx) req
```

Currently, 20+ modules reach into `CfnContext` via `cfnEnv ctx`. With a typeclass + lens, those modules depend on the _capability_ (having an AWS env) rather than the _concrete type_ (being a full `CfnContext`). Read-only operations could pass a simpler type that still satisfies `HasCfnEnv`.

**An `Emittable` class** would formalize the output dispatch:

```haskell
class Emittable a where
  renderInteractive :: InteractiveRenderer -> a -> IO ()
  renderJson :: JsonRenderer -> a -> IO ()
```

Currently, `renderOutputData` is a 27-arm case statement matching `OutputData` constructors. An open typeclass would let new output types be added without modifying the central dispatcher — though this trades exhaustiveness checking for extensibility.

---

## 2. No Optics. Manual Record Access Everywhere.

The codebase uses `microlens` (it's in the cabal file) but only for amazonka field access. Custom types use raw record selectors:

```haskell
-- Instead of:
ctx ^. cfnEnvL . to Amazonka.envRegion

-- You see:
Amazonka.envRegion (cfnEnv ctx)
```

For flat records this is fine. For nested access it gets verbose:

```haskell
case lookupO "Properties" kvs of
  Just (OObject props) -> case lookupO "Type" props of
    Just (OString typeName) -> ...
```

This is exactly the kind of nested `Maybe`-returning lookup that optics handle gracefully:

```haskell
kvs ^? key "Properties" . _OObject . key "Type" . _OString
```

### Where Optics Would Help Most

**OValue traversals.** `OValue` is a recursive sum type — the canonical case for prisms and traversals. Currently, every function that walks an `OValue` tree does manual pattern matching:

```haskell
rewriteRefs prefix globals = rewrite
  where
    rewrite val = case val of
      OObject kvs -> OObject (rewriteObject prefix globals kvs)
      OArray items -> OArray (map rewrite items)
      _ -> val
```

With optics:

```haskell
-- A Traversal over all nested OValues in an OValue tree
deepValues :: Traversal' OValue OValue

-- Rewrite all Ref strings:
rewriteAllRefs prefix globals =
  over (deepValues . _OObject . filtered isRefSingleton) (rewriteRef prefix globals)
```

**The `TagContext` update pattern.** `withVariable`, `withBindings` are manual record update functions. With lenses, `!$let` binding becomes:

```haskell
over tcVariablesL (Map.insert name val) ctx
```

---

## 3. The Monad Stack That Isn't

The resolver returns `Either ResolveError OValue`. The engine returns `IO (Either Text PreprocessResult)`. CFN operations return `IO (Either Text Int)`. The error types are different at every layer.

Kmett would recognize this as a **monad transformer stack begging to be formalized**:

```haskell
-- What the code implicitly does:
type Resolve a = Either ResolveError a           -- pure resolution
type Engine a  = IO (Either Text a)              -- IO with string errors
type CfnOp a  = IO (Either Text a)              -- same but in the CFN layer
```

The `Either` is threaded manually with `case` and early return. A `MonadError`-based stack would give you `throwError` and `catchError` uniformly:

```haskell
type Resolve a = ExceptT ResolveError Identity a    -- pure
type Engine a  = ExceptT EngineError IO a            -- IO + structured errors
type CfnOp a  = ExceptT CfnError IO a               -- IO + typed errors

-- Now error propagation is automatic:
resolveAst :: TagContext -> YamlAst -> Resolve OValue
resolveAst ctx (AstPreprocessingTag tag meta) = do
  case tag of
    PpIf ifTag -> resolveIf ctx meta ifTag  -- errors propagate via MonadError
    ...
```

The benefit isn't just syntactic sugar. It's that **error handling becomes uniform**. The five error handling patterns (see Hickey review) collapse to one: `MonadError e m`. The `fail` calls in `TemplateLoader` become `throwError`. The `catch + stderr` in `Sts.hs` becomes `catchError`. The silent `SomeException` swallowing becomes a `catchError` that maps to a specific error constructor.

### Why This Wasn't Done (and Why That's OK)

The project instructions say "plain IO with CfnContext passed explicitly." This is a reasonable choice for a port — matching the Rust implementation's imperative style makes differential testing easier. Adding MTL would change the function signatures throughout, making it harder to verify equivalence with Rust.

But the cost is visible: 5 error patterns, manual `case` threading, and no common error algebra.

---

## 4. OValue Wants to Be a Recursive Scheme

`OValue` is a fixed-point of a base functor:

```haskell
data OValueF a
  = ONullF
  | OBoolF !Bool
  | ONumberF !Scientific
  | OStringF !Text
  | OArrayF ![a]
  | OObjectF ![(Text, a)]
  deriving (Functor, Foldable, Traversable)

type OValue = Fix OValueF
```

With `recursion-schemes`, the entire resolution pipeline would gain access to:
- `cata` (catamorphism) for evaluating `OValue` trees
- `ana` (anamorphism) for building `OValue` trees
- `para` (paramorphism) for transformations that need both the subtree and its reduced form
- `hylo` for fused build-then-fold operations

Currently, every function that walks an `OValue` tree reimplements the recursion pattern manually. `rewriteRefs`, `collectGlobalRefs`, `emitYaml`, `toValue`, `fromValue` — each one is a hand-written catamorphism.

Would this be worth it? Kmett would say yes — the abstraction eliminates an entire class of bugs (forgetting to recurse into a constructor) and makes tree transformations composable. A pragmatist might say the manual versions are clearer and the `Fix` indirection hurts readability.

---

## 5. The YamlAst ↔ OValue ↔ Value Triangle

Three value representations live in the system simultaneously:

```
YamlAst    — parsed YAML with source locations and tags
  │
  │ resolveAst (pure, tree walk)
  ▼
OValue     — resolved values with ordered keys ([(Text, OValue)])
  │
  │ toValue / fromValue
  ▼
Value      — aeson JSON with unordered keys (KeyMap Value)
```

The conversions form a triangle with **information loss**:

- `YamlAst → OValue`: Loses source locations, tag structure. Irreversible.
- `OValue → Value`: Loses key ordering. Reversible only because aeson 2.x happens to use an ordered keymap internally.
- `Value → OValue`: Currently "preserves" order, but this is an implementation detail of aeson's `KeyMap`, not a guarantee.

Kmett would want **phantom types** or **indexed types** to make the information flow explicit:

```haskell
newtype Tagged (phase :: Phase) a = Tagged a
data Phase = Parsed | Resolved | Serializable

-- Resolution only works on Parsed values:
resolveAst :: TagContext -> Tagged 'Parsed YamlAst -> Either ResolveError (Tagged 'Resolved OValue)

-- toValue only works on Resolved values:
toValue :: Tagged 'Resolved OValue -> Tagged 'Serializable Value
```

This is over-engineering for this codebase. But the underlying observation is sound: the three types represent three phases of processing, and the implicit phase transitions are a source of bugs (e.g., the JMESPath OValue→Value→OValue round-trip in the resolver).

---

## 6. The `(OutputData -> IO ())` Callback Is a Free Monad in Disguise

Every CFN operation takes `(OutputData -> IO ()) -> IO (Either Text Int)`. The emit callback is the operation's only way to communicate intermediate results. The operation decides _what_ to emit and _when_; the callback decides _how_.

This is the operational semantics of a free monad:

```haskell
data CfnF next
  = Emit OutputData next
  | SendAws (AWSRequest a) (AWSResponse a -> next)
  | GetTime (UTCTime -> next)
  | Log Text next
  deriving Functor

type CfnOp = Free CfnF

-- Operations become pure descriptions:
createStack :: StackArgs -> CfnOp Int
createStack args = do
  emit (OdStackDefinition ...)
  resp <- sendAws (buildCreateStackRequest ...)
  emit (OdPollingStarted "Polling...")
  pollResult <- pollForCompletion ...
  emit (OdStackContents ...)
  pure 0
```

With a free monad, you could:
- **Interpret in IO** (production): actually send AWS requests and emit to the terminal.
- **Interpret purely** (testing): collect emitted `OutputData` values in a list, mock AWS responses from a fixture.
- **Interpret in a log** (debugging): record every AWS request without sending it.

Currently, testing CFN operations requires either live AWS (untestable offline) or the single DI point `pollForCompletionWith`. A free monad would make every operation testable in isolation.

### Why This Wasn't Done

Free monads have runtime overhead (allocating `Free` constructors) and cognitive overhead (the pattern is unfamiliar to many Haskellers). The callback approach is simpler and matches the Rust implementation's trait-object pattern. For a port, pragmatism wins.

---

## 7. Missing Abstractions for Import Loaders

The 10 import loaders follow a nearly identical pattern:

```haskell
loadFileImport    :: Text -> Text -> IO (Either ImportError ImportData)
loadEnvImport     :: Text -> IO (Either ImportError ImportData)
loadGitImport     :: Text -> Text -> IO (Either ImportError ImportData)
loadSsmImport     :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
loadHttpImport    :: Text -> IO (Either ImportError ImportData)
...
```

They differ in:
- Whether they need an `Amazonka.Env`
- Whether they need a `baseLocation` for relative path resolution
- The parsing/extraction logic specific to each import type

But the structure is identical: parse the location URI, fetch the content, parse the content, wrap in `ImportData`. There's no shared abstraction for this pattern — each loader reimplements the error wrapping, content parsing, and result construction.

A Kmett-style approach would factor out the common structure:

```haskell
class ImportLoader a where
  type LoaderEnv a :: Type
  parseLocation :: Text -> Either ImportError (LocationInfo a)
  fetchContent  :: LoaderEnv a -> LocationInfo a -> IO (Either ImportError ByteString)
  parseContent  :: ByteString -> Either ImportError ImportData

-- Generic loader:
runLoader :: ImportLoader a => LoaderEnv a -> Text -> IO (Either ImportError ImportData)
runLoader env loc = runExceptT $ do
  info <- liftEither $ parseLocation loc
  content <- ExceptT $ fetchContent env info
  liftEither $ parseContent content
```

This factors the three concerns (parse location, fetch content, parse result) into independent, testable pieces. Each loader implements the typeclass; the generic runner handles the plumbing.

---

## 8. The Status Strings Want a Prism

Stack statuses are `Text` everywhere. But they're pattern-matched as strings:

```haskell
case status of
  "CREATE_COMPLETE" -> ...
  "DELETE_FAILED" -> ...
```

If they were a proper type with prisms:

```haskell
_CreateComplete :: Prism' StackStatus ()
_DeleteFailed :: Prism' StackStatus ()

-- Or just pattern synonyms:
pattern CreateComplete <- (preview _CreateComplete -> Just ())
```

More practically, Kmett would encode the _categories_ as a type:

```haskell
data StatusPhase = Create | Update | Delete | Rollback | Import
data StatusOutcome = Complete | Failed | InProgress | Skipped

parseStatus :: Text -> Maybe (StatusPhase, StatusOutcome)
```

Now `isTerminal` is a function of `StatusOutcome`, not a membership check in a list of strings.

---

## 9. What's Actually Good From Kmett's Perspective

**The `TimeProvider` record-of-functions.** This is a lightweight effects abstraction:

```haskell
data TimeProvider = TimeProvider
  { tpNow       :: IO UTCTime
  , tpStartTime :: IO UTCTime
  }
```

Three implementations: `systemTimeProvider`, `reliableTimeProvider`, `mockTimeProvider`. This is exactly how Kmett's `reflection` library approaches runtime configuration — a dictionary of operations that can be swapped at the call site. It's the practical alternative to a typeclass when you don't need dispatch.

**The `LoadImportFn` injection.** `type LoadImportFn = Text -> Text -> IO (Either ImportError ImportData)` — a first-class function as the abstraction boundary between the engine and the import system. Clean, testable, no typeclass ceremony.

**Strict `!` annotations everywhere.** Every record field is strict. No space leaks from lazy accumulation. This shows awareness of Haskell's evaluation model.

**The `OValue` design choice.** Using `[(Text, OValue)]` instead of `Map Text OValue` for ordered keys is a conscious performance trade-off. The O(n) lookup is justified with a comment citing the typical CFN template size (5-30 keys). This is the kind of domain-specific optimization that Kmett respects — knowing your data well enough to choose the right representation.

**`resolveAst` as a total function.** `Either ResolveError OValue` — no exceptions, no bottoms, no `undefined`. The resolver is a total function from valid ASTs to values or errors. This is exactly how pure evaluation should work.

---

## Verdict

This codebase is **pragmatic Haskell** — it uses the language's strengths (algebraic data types, pattern matching, `Either` for errors, purity where possible) while avoiding its more exotic features (typeclasses, optics, free monads, recursion schemes, GADTs, type families).

For a port of a Rust codebase where behavioral equivalence is the primary goal, this is the right call. Every abstraction that changes function signatures makes differential testing harder. The "Haskell as a better Java" style ensures that the Haskell code's structure mirrors the Rust code's structure, which is what you want when 98 snapshots must match.

But if this codebase outlives the port — if it becomes the maintained implementation, not just a translation — then the abstractions Kmett would reach for start to pay off. The import loader pattern wants a typeclass. The OValue tree walks want recursion schemes. The error handling wants `ExceptT`. The CFN operations want a free monad (or at minimum, a `ReaderT CfnEnv IO`).

The codebase has earned the right to graduate from "port" to "native Haskell." Whether it should is a question of maintenance trajectory, not engineering quality.
