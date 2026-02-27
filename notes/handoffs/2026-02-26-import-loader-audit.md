# Import Loader Audit & Completion -- Multi-Chunk Implementation

**Date**: 2026-02-26
**Session**: `45486b57-0915-4ae0-9839-16e541f856ec`
**References**: Rust source `~/src/iidy/src/yaml/imports/loaders/` (read-only), `src/Iidy/Yaml/Imports/`

## Context

The import system has 11 `ImportType` variants but only 4 are wired end-to-end
(File, Filehash, FilehashBase64, Env-in-GetImport-only). The remaining 7 loaders
are either complete but unreachable, have wrong return types, or are missing entirely.

This session added `loadFilehashImport` + `dispatchLocalImport` (committed `d3eb260`).
The audit revealed the full scope of what remains.

## Key Architecture Decisions

### Flat enum, subtypes in location parsing
Rust uses a flat `ImportType` enum. CFN's 6 subtypes (output, export, parameter, tag,
resource, stack) are discriminated by parsing the location string, not enum variants.
Keep the same pattern in Haskell.

### Two dispatch points
1. **`dispatchLocalImport`** in `Loaders/File.hs` — used by the Engine pipeline
   (`Render.hs`, `Demo.hs`, `StackArgsLoader.hs`). This is the `LoadImportFn`.
2. **`loadImportByType`** in `GetImport.hs` — used only by the `get-import` CLI command.

The Engine dispatcher needs to become a full multi-type dispatcher (not just local
imports). AWS loaders need an `Amazonka.Env` parameter, so the dispatcher signature
must change to accept optional AWS config.

### AWS loader return type
S3/Ssm/Cfn currently return `Either Text Text`. They need to return
`Either ImportError ImportData` to match the pipeline. Each needs content-type
detection (JSON/YAML parsing by extension or format suffix).

## Chunks

### Chunk 1: Wire local loaders into dispatcher + tests

**Scope**: Env, Git, Random — all have complete implementations with correct signatures.

**Changes**:

`src/Iidy/Yaml/Imports/Loaders/File.hs` — expand `dispatchLocalImport`:
```haskell
dispatchLocalImport location baseLocation
  | "filehash-base64:" `T.isPrefixOf` location = loadFilehashImport location baseLocation True
  | "filehash:" `T.isPrefixOf` location = loadFilehashImport location baseLocation False
  | "env:" `T.isPrefixOf` location = loadEnvImport location
  | "git:" `T.isPrefixOf` location = loadGitImport location baseLocation
  | "random:" `T.isPrefixOf` location = loadRandomImport location
  | otherwise = loadFileImport location baseLocation
```

`src/Iidy/GetImport.hs` — add Git, Random cases:
```haskell
loadImportByType ImportGit location base = loadGitImport location base
loadImportByType ImportRandom location _base = loadRandomImport location
```

**Tests** (in `test/Test/ImportLoaderTest.hs` or separate files):

- **Env**: set env var → load → check value; default fallback; missing var error
- **Git**: `git:branch` returns non-empty text; `git:sha` returns 40-char hex;
  invalid command errors
- **Random**: `random:dashed-name` matches `/^\w+-\w+$/`; `random:int` in 1-999;
  `random:name` non-empty; invalid type errors

### Chunk 2: Wire Http loader + tests

**Scope**: Http has a complete implementation with correct signature.

**Changes**:

`dispatchLocalImport` — add `http://`/`https://` prefix routing:
```haskell
  | "http://" `T.isPrefixOf` location || "https://" `T.isPrefixOf` location =
      loadHttpImport location
```

`GetImport.hs` — add:
```haskell
loadImportByType ImportHttp location _base = loadHttpImport location
```

**Tests**: Http is hard to unit test (needs network). Options:
- Skip unit tests, rely on integration/live testing
- Test `urlPath` and `parseByExtension` helpers if exported
- Mock via a local HTTP server (heavy)

Recommend: export and test `urlPath` helper only. Http tested via live verification.

### Chunk 3: Fix AWS loader return types (S3, Ssm, Cfn)

**Scope**: Change return type from `Either Text Text` to `Either ImportError ImportData`.
Add content-type detection.

**S3.hs** changes:
```haskell
loadS3Import :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
-- After fetching text, parse by extension (like Http does)
-- Return ImportData { idType = ImportS3, idLocation = location, idRawData = content, idDoc = parsed }
```

**Ssm.hs** changes:
```haskell
loadSsmImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
-- Parse optional format suffix (:json, :yaml)
-- Return ImportData { idType = ImportSsm, ... }
```

**Cfn.hs** changes:
```haskell
loadCfnImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
-- Return ImportData { idType = ImportCfn, ... }
-- For now, output-only is acceptable (matches what we have)
```

**Tests**: All AWS loaders use mock fixtures (no real AWS calls per CLAUDE.md).
Each needs a mock `Amazonka.Env` or a trait-like pattern. Consider testing
the pure parsing functions (parseS3Uri, parseCfnRef, stripSsmPrefix) separately.

### Chunk 4: Add SsmPath loader

**Scope**: Completely missing. Rust uses `GetParametersByPath` API to fetch
all params under a path recursively, returning them as a JSON object with
relative keys.

**New file**: `src/Iidy/Yaml/Imports/Loaders/SsmPath.hs` (or add to Ssm.hs):
```haskell
loadSsmPathImport :: Amazonka.Env -> Text -> IO (Either ImportError ImportData)
-- Parse ssm-path:/path/prefix
-- Call GetParametersByPath with recursive=True
-- Build Object with relative keys (strip prefix from param names)
-- Return ImportData { idType = ImportSsmPath, idDoc = Object mapping, ... }
```

### Chunk 5: Create full dispatcher with AWS config

**Scope**: Replace `dispatchLocalImport` (local-only) with a full dispatcher
that can route to AWS loaders when AWS config is available.

**Architecture options**:

A) **Expand `LoadImportFn`** to carry optional AWS env:
```haskell
type LoadImportFn = Text -> Text -> IO (Either ImportError ImportData)
mkDispatcher :: Maybe Amazonka.Env -> LoadImportFn
```

B) **Partial application** — construct the dispatcher at call site:
```haskell
let loader = mkFullDispatcher (Just awsEnv)
result <- preprocessYaml11 loader ast baseLocation
```

Option B is cleaner. The `Render.hs` path doesn't have AWS env, so it passes
`mkFullDispatcher Nothing` (AWS imports error). The CFN path in `StackArgsLoader.hs`
has `CfnContext` with AWS env, so it passes `mkFullDispatcher (Just env)`.

**Changes**:
- `Loaders/File.hs`: rename `dispatchLocalImport` → keep as fallback
- New `Loaders/Dispatch.hs` or inline: `mkFullDispatcher`
- `Render.hs`: `mkFullDispatcher Nothing`
- `StackArgsLoader.hs`: `mkFullDispatcher (Just awsEnv)`
- `GetImport.hs`: refactor `loadImportByType` to use same dispatcher

### Chunk 6: Cfn subtypes (output, export, parameter, tag, resource, stack)

**Scope**: Rust has 6 CFN subtypes dispatched by location string format.
Current Haskell only handles `cfn:stack/output` (legacy dot/slash syntax).

**Location formats to support**:
- `cfn:stack.OutputKey` (legacy) → single output
- `cfn:output:stack/Key` → single output
- `cfn:output:stack` → all outputs as mapping
- `cfn:export:Name` → single export
- `cfn:parameter:stack/Key` → single parameter
- `cfn:parameter:stack` → all parameters
- `cfn:tag:stack/Key` → single tag
- `cfn:tag:stack` → all tags
- `cfn:resource:stack/LogicalId` → single resource
- `cfn:resource:stack` → all resources
- `cfn:stack:stack` → full stack (Outputs + Parameters + Tags)

Each needs new AWS API calls (ListExports, DescribeStackResources, etc.)
and result→ImportData conversion.

This is the largest chunk and can be split further if needed.

## Codebase Reference

| What                    | Where                                          |
|-------------------------|-------------------------------------------------|
| ImportType enum         | `src/Iidy/Yaml/Imports/Types.hs` (lines 18-30) |
| parseImportType         | `src/Iidy/Yaml/Imports/Types.hs` (lines 56-80) |
| dispatchLocalImport     | `src/Iidy/Yaml/Imports/Loaders/File.hs` (line 33) |
| loadImportByType        | `src/Iidy/GetImport.hs` (line 64)              |
| Engine LoadImportFn     | `src/Iidy/Yaml/Engine.hs` (line 44)            |
| Engine processImports   | `src/Iidy/Yaml/Engine.hs` (line 137)           |
| Render caller           | `src/Iidy/Render.hs` (line 64)                 |
| StackArgsLoader caller  | `src/Iidy/Cfn/StackArgsLoader.hs` (line 76)    |
| Demo caller             | `src/Iidy/Demo.hs` (line 72)                   |
| Env loader              | `src/Iidy/Yaml/Imports/Loaders/Env.hs` (39 LOC, complete) |
| Git loader              | `src/Iidy/Yaml/Imports/Loaders/Git.hs` (73 LOC, complete) |
| Random loader           | `src/Iidy/Yaml/Imports/Loaders/Random.hs` (64 LOC, complete) |
| Http loader             | `src/Iidy/Yaml/Imports/Loaders/Http.hs` (98 LOC, complete) |
| S3 loader               | `src/Iidy/Yaml/Imports/Loaders/S3.hs` (77 LOC, wrong sig) |
| Ssm loader              | `src/Iidy/Yaml/Imports/Loaders/Ssm.hs` (56 LOC, wrong sig) |
| Cfn loader              | `src/Iidy/Yaml/Imports/Loaders/Cfn.hs` (104 LOC, wrong sig) |
| Rust cfn loader         | `~/src/iidy/src/yaml/imports/loaders/cfn.rs` (6 subtypes) |
| Rust ssm loader         | `~/src/iidy/src/yaml/imports/loaders/ssm.rs` (ssm + ssm-path) |
| Rust dispatcher         | `~/src/iidy/src/yaml/imports/loaders/mod.rs` (lines 57-97) |

## Build/Test Commands

Per CLAUDE.md — use `~/.claude/bin/run-quiet` wrapper.

## Delegation Strategy

| Chunk | Can delegate? | Sub-agent type | Notes |
|-------|--------------|----------------|-------|
| 1     | Yes          | Sonnet         | Mechanical wiring + simple tests, clear spec |
| 2     | Yes          | Sonnet         | Simple wiring, minimal tests |
| 3     | Yes          | Sonnet         | Signature changes with clear pattern to follow |
| 4     | Yes          | Sonnet         | New module following established pattern |
| 5     | No           | Opus           | Architecture decision on dispatcher shape |
| 6     | Partially    | Opus design, Sonnet impl | Location parsing is mechanical but API surface needs design |

## Workflow Instructions

1. Read this file first
2. Check Progress for what's next
3. Chunks 1-2 are independent and can be done in parallel
4. Chunk 3 must precede Chunk 5
5. Chunk 4 depends on Chunk 3's SSM pattern
6. Chunk 5 must precede Chunk 6 (full dispatcher needed)
7. After completing work, update Progress and add Handoff Notes
8. Record session ID in each entry

## Progress

- [x] Chunk 1: Wire Env/Git/Random into dispatcher + tests (`6baaa0c`)
- [x] Chunk 2: Wire Http loader + tests (`6baaa0c`)
- [x] Chunk 3: Fix AWS loader return types (S3, Ssm, Cfn) (`32f2f51`)
- [ ] Chunk 4: Add SsmPath loader
- [ ] Chunk 5: Create full dispatcher with AWS config
- [ ] Chunk 6: Cfn subtypes (output, export, parameter, tag, resource, stack)
- [ ] Final: `cabal build` zero warnings + `cabal test` all pass

## Handoff Notes

### Initial Audit (2026-02-26)

**Session**: `45486b57-0915-4ae0-9839-16e541f856ec`
**Completed**: Filehash loader implementation + full audit of all 11 import types
**Files created/modified**:
- `src/Iidy/Yaml/Imports/Loaders/File.hs` — added `loadFilehashImport`, `dispatchLocalImport`
- `src/Iidy/GetImport.hs` — added Filehash/FilehashBase64 cases
- `src/Iidy/Render.hs`, `Demo.hs`, `StackArgsLoader.hs` — switched to `dispatchLocalImport`
- `test/Test/FilehashTest.hs` — 11 new tests
- Committed as `d3eb260`
**Deviations from plan**: N/A (this is the initial handoff)
**Notes for next chunk**: The `dispatchLocalImport` function in `File.hs` is the
natural place to add Env/Git/Random routing. Env loader takes only `location`
(no baseLocation), Git takes both, Random takes only `location`.

### Chunks 1+2 (2026-02-26)

**Session**: current
**Completed**: Wired all local loaders (Env, Git, Random, Http) into both dispatchers
**Files modified**:
- `src/Iidy/Yaml/Imports/Loaders/File.hs` — expanded `dispatchLocalImport` with 6 new routes (env/git/random/http/https + AWS error guard)
- `src/Iidy/GetImport.hs` — added Git/Random/Http cases to `loadImportByType`
- `src/Iidy/Yaml/Imports/Loaders/Http.hs` — exported `urlPath`, fixed query string/fragment stripping
- `test/Test/ImportLoaderTest.hs` — 20 new tests (env, git, random, http helpers, dispatcher routing)
- Committed as `6baaa0c`
**Deviations from plan**: Combined Chunks 1+2 into single commit since both modify same files.
**Review findings addressed**:
- AWS prefixes (cfn/ssm/ssm-path/s3) now return explicit error instead of falling through to file loader
- `urlPath` strips query strings and fragments for correct extension detection
- Added AWS-prefix-error test and fragment-stripping test
**Review findings deferred**:
- Extract dispatcher to own module → Chunk 5
- `loadHttpImport` direct tests → requires network, per handoff plan only `urlPath` tested

### Chunk 3 (2026-02-26)

**Session**: current
**Completed**: All 3 AWS loaders now return `Either ImportError ImportData`
**Files modified**:
- `src/Iidy/Yaml/Imports/Loaders/S3.hs` — full rewrite: return ImportData, extension-based parsing with strict errors (matching JS), export parseS3Uri
- `src/Iidy/Yaml/Imports/Loaders/Ssm.hs` — full rewrite: return ImportData, `:json`/`:yaml` format suffix parsing, export parseSsmLocation
- `src/Iidy/Yaml/Imports/Loaders/Cfn.hs` — return ImportData, removed dot separator (JS doesn't have it), export parseCfnRef
- `test/Test/AwsLoaderTest.hs` — 17 new tests for pure parsing helpers
- `docs/requirements/03-import-system.md` — PRD fixes: removed dot syntax refs, fixed S3 parse failure behavior
- Committed as `32f2f51`
**Deviations from plan**:
- Removed legacy dot syntax (`cfn:Stack.Key`) — JS source of truth does not support it
- S3 parse failure is now an error (matching JS), not fallback-to-string as PRD originally said
**JS source of truth discrepancies found**:
- JS throws on S3/file YAML/JSON parse failure; old PRD said "fall back to string" → fixed
- JS has no `cfn:Stack.Key` dot syntax; was a Rust-only addition → removed
- SSM format suffix parsing matches both JS and Rust: split on `:` after prefix
**Notes for next chunk**: Chunk 4 (SsmPath) depends on the SSM pattern established here. Chunk 5 (full dispatcher) needs AWS env parameter threading.
