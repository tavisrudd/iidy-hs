# Investigate ReaderT / RIO Pattern for Threading Configuration

**Date**: 2026-03-03
**Purpose**: Evaluate whether a ReaderT/RIO pattern would reduce parameter threading boilerplate in iidy-hs.

---

## Context

The codebase currently threads configuration through explicit function parameters. Recent additions (e.g., `RemoteImports`, `ImportConfig`) have deepened the threading chains — a flag added to `GlobalOpts` must be manually plumbed through 10+ files (Main → runCfnWithArgs → operation → request builder → template loader → dispatcher).

A ReaderT or RIO-style pattern could bundle shared read-only context (AWS env, remote import policy, environment name, debug flag, etc.) into an environment that's implicitly available, eliminating most of the parameter passing.

## Scope

- **In scope**: Evaluate ReaderT / Has-class / RIO patterns for the CFN operation call chain and import dispatcher
- **In scope**: Prototype on one vertical slice (e.g., create-stack path) to assess ergonomics
- **Out of scope**: Rewriting the entire codebase; this is a feasibility study first
- **Out of scope**: Adding new dependencies (prefer `transformers` ReaderT which is already a transitive dep)

## Work Items

1. **Audit current threading patterns** — catalog what's being threaded through the CFN operation chain:
   - `CfnContext` (AWS env, tokens, timing)
   - `RemoteImports` (new)
   - `StackArgs`
   - `Maybe FilePath` (argsfile path)
   - `Text` (environment name)
   - `OutputData -> IO ()` (emitter)
   - Identify which are truly read-only vs. modified

2. **Design candidate environment type** — e.g.:
   ```haskell
   data AppEnv = AppEnv
     { aeAwsEnv        :: !(Maybe Amazonka.Env)
     , aeRemoteImports :: !RemoteImports
     , aeEnvironment   :: !Text
     , aeEmit          :: !(OutputData -> IO ())
     , aeDebug         :: !Bool
     }
   ```

3. **Evaluate trade-offs**:
   - Explicit params: verbose but grep-friendly, no monad transformer overhead
   - ReaderT: less boilerplate but harder to trace data flow, adds `MonadReader` constraint
   - RIO: opinionated but well-documented pattern
   - Has-class: flexible but more typeclass machinery

4. **Prototype** on one path (create-stack) and compare before/after

## Codebase Reference

| What                          | Where                                              |
|-------------------------------|----------------------------------------------------|
| Main dispatch / runCfnWithArgs | `app/Main.hs:344`                                 |
| Import dispatcher config      | `src/Iidy/Yaml/Imports/Loaders/Dispatch.hs`        |
| CFN operation examples         | `src/Iidy/Cfn/Operations/CreateStack.hs`           |
| Request builder (deep threading) | `src/Iidy/Cfn/RequestBuilder.hs`                 |
| Template loader                | `src/Iidy/Cfn/TemplateLoader.hs`                   |

## Principles / Constraints

- `transformers` is already available (transitive dep). Prefer it over adding `mtl` or `rio`.
- Keep `-Wall -Wcompat` clean
- The YAML engine (`preprocessYaml`) uses `LoadImportFn = Text -> Text -> IO (Either ImportError ImportData)` — any reader pattern must be compatible with this callback type (likely by `runReaderT` at the boundary)

## Delegation

- **Can delegate to sub-agent?** Yes (research phase)
- **Model**: Opus (architectural evaluation)
- **Notes**: Research only — no code changes until approach is approved
