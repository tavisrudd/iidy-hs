# iidy-hs Coding Standards

Project-specific conventions and the reasoning behind them.

## Language & Compiler

- **GHC2021** with `base >= 4.17 && < 5` (GHC 9.6+)
- Default extensions in cabal: `DerivingStrategies`, `LambdaCase`, `OverloadedStrings`
- `OverloadedRecordDot` enabled per-module where amazonka APIs are called
- `-Wall -Wcompat`, zero warnings on every commit
- All record fields use `!` except newtypes
- Always `import qualified Data.List as List` — GHC 9.6 doesn't re-export `foldl'` from Prelude but 9.10+ does, so an unqualified selective import triggers `-Wunused-imports` on 9.10

---

## Import Conventions

### Always-Qualified Libraries

| Module                      | Alias  |
|:----------------------------|:-------|
| `Amazonka`                  | —      |
| `Amazonka.CloudFormation.*` | `CS`   |
| `Data.Aeson`                | `Aeson`|
| `Data.Aeson.Key`            | `Key`  |
| `Data.Aeson.KeyMap`         | `KM`   |
| `Data.Map.Strict`           | `Map`  |
| `Data.Set`                  | `Set`  |
| `Data.Vector`               | `V`    |
| `Data.Text`                 | `T`    |
| `Data.Text.Encoding`        | `TE`   |
| `Data.Text.IO`              | `TIO`  |
| `Data.ByteString.Lazy`      | `BL`   |
| `Data.Scientific`           | `Sci`  |
| `Data.List`                 | `List` |

### Import Block Order

1. Standard library → 2. Third-party → 3. Project-internal

Post-qualified syntax throughout. Internal modules that are closely related may be imported unqualified.

---

## Type Design

### Record Field Prefixes

amazonka 2.0 uses `DuplicateRecordFields`, so our own types use **lowercase prefix abbreviations** to avoid collisions without enabling that extension for project code (e.g. `GlobalOpts` → `go`, `StackArgs` → `sa`, `CfnContext` → `cfn`).

### Sum Type Constructor Prefixes

Commands use `Cmd`, operations use `Op`, output data uses `Od`. Errors carry structured info types (e.g. `VariableNotFoundError !VariableNotFoundInfo`).

### OValue — Why Not Aeson Value

`OValue` preserves mapping key insertion order (CloudFormation templates are order-sensitive). Objects are `[(Text, OValue)]` association lists — O(n) lookup is fine because CF mappings are typically 5–30 keys.

### Other Type Rules

- Newtypes for domain concepts crossing module boundaries; type aliases only for module-local shorthand
- Always `deriving stock`, never bare `deriving`

---

## IO & Effects

### Plain IO — No Transformer Stack

No `ReaderT`, no `ExceptT`, no custom `App` monad. Configuration passed as explicit arguments. YAML resolution is pure (`Either ResolveError a`).

### Mutable State

`IORef` for mutation. `TVar`/STM only for the spinner's cross-thread state.

### Output Callback Pattern

Operations emit output via `cfnEmit :: OutputData -> IO ()` on `CfnContext`, decoupling operations from rendering.

---

## Error Handling

### Banned

`head`, `tail`, `init`, `last`, `fromJust`, `read`, `(!!)`, `error "TODO"`, `undefined`.

### Conventions

- Operations return `Either Text a` or `Either SomeErrorType a` — no exceptions for expected failures
- Errors carry structured metadata (position, kind, suggestions) for classification and display

### Error Code Numbering (`Iidy.Yaml.Errors.Ids`)

| Range | Category                |
|:------|:------------------------|
| 1xxx  | YAML Syntax & Parsing   |
| 2xxx  | Variable & Scope        |
| 3xxx  | Import & Loading        |
| 4xxx  | Tag Syntax & Structure  |
| 5xxx  | Type & Validation       |
| 6xxx  | Template & Handlebars   |
| 7xxx  | CloudFormation Specific |
| 8xxx  | Configuration & Setup   |
| 9xxx  | Internal & System       |

Display form: `ERR_1001`, `ERR_2001`, etc. Bidirectional mapping via `errorIdCode`/`errorIdFromCode`.

---

## Module Organization

- ~300–500 LOC target; split larger modules into sub-modules
- Every module has an explicit export list with section comments
- See `src/Iidy/` tree for canonical hierarchy

---

## AWS Integration

- `OverloadedRecordDot` for response field access, request types imported qualified
- All API calls wrapped in `runResourceT`
- Credentials resolved by `Amazonka.discover`; a parallel detection layer determines provenance for display
- Region priority: CLI flag > stack-args > `AWS_REGION` > `AWS_DEFAULT_REGION` > error (no silent us-east-1 default)

---

## Testing

- **tasty** + **tasty-hunit** + **tasty-quickcheck**
- One module per concern under `test/Test/`, each exporting `fooTests :: [TestTree]` or `IO TestTree`
- `Test.Shared` provides deterministic builder functions for all major types
- All AWS testing uses mock fixtures — no real AWS calls
- Property tests use `sized`/`resize` to bound recursion depth

---

## Build

- `library` / `executable` / `test-suite` in one cabal file
- `-O0`, `-threaded -rtsopts -with-rtsopts=-N` for dev
- **Dual dependency tracking**: new deps go in BOTH `iidy-hs.cabal` AND `flake.nix`

---

## Style

- Point-free when it clarifies (e.g. `map userName`), named arguments when composition gets opaque
- Use `maybe (Left err) Right` or `note`-style combinators to flatten `Maybe`-to-`Either` chains in do blocks instead of nested `case` matching

---

## Banned

`undefined`, `error "TODO"`, partial functions, orphan instances (except tests with `-Wno-orphans`), duplicate code, placeholder stubs, unnecessary dependencies, bare `String` in domain types
