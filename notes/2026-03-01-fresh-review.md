# Fresh Due-Diligence Review -- 2026-03-01

## Summary

Comprehensive code review of iidy-hs, an 86-module (~17,800 LOC) Haskell port of a Rust CloudFormation preprocessor/deployer. The codebase is well-structured, compiles cleanly with `-Wall -Wcompat`, and has 958 tests. Architecture decisions (custom JMESPath, custom Handlebars, OValue for key ordering, plain IO monad) are sound.

**Findings by severity:**
- Critical: 1
- High: 5
- Medium: 7
- Low/Info: 5

## Critical Findings

### C-1: SSM GetParametersByPath missing pagination in SsmPath loader and GlobalConfig

**Files:**
- `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Imports/Loaders/SsmPath.hs` lines 62-72
- `/home/tavis/src/iidy-hs/src/Iidy/Cfn/GlobalConfig.hs` lines 103-111

Both `fetchParametersByPath` functions issue a single `Amazonka.send` and return only the first page of results. SSM GetParametersByPath returns at most 10 parameters per page by default. If a user has more than 10 parameters under a path prefix (common for `ssm-path:` imports) or under `/iidy/` (less likely but possible), results will be silently truncated.

Compare with `Params/Client.hs:118` which correctly uses `Amazonka.paginate`:
```haskell
pages <- runConduit $ Amazonka.paginate awsEnv req .| CL.consume
```

The SsmPath and GlobalConfig functions only do:
```haskell
resp <- Amazonka.send awsEnv req
let params = fromMaybe [] resp.parameters
```

This is a data loss bug -- parameters beyond the first page are silently dropped. The Rust version also appears to lack pagination in `get_parameters_by_path` (single `.send().await`), so this may be a shared bug. However, the Haskell code should fix it regardless.

## High Findings

### H-1: resolveEnvMaps silently swallows missing environment errors

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackArgsLoader.hs` lines 121-128

When a Profile/Region/AssumeRoleARN field contains an environment map (e.g., `{staging: "prof-a", prod: "prof-b"}`) and the current environment is not found in the map, the Haskell code silently leaves the entire Object as-is:

```haskell
resolveEnvMapField obj key env =
  case KM.lookup (Key.fromText key) obj of
    Just (Object envMap) ->
      case KM.lookup (Key.fromText env) envMap of
        Just val -> KM.insert (Key.fromText key) val obj
        Nothing  -> obj  -- env not found, leave as-is  <-- BUG
    _ -> obj
```

The Rust version errors out in this case:
```rust
None => bail!("environment '{env}' not found in {key} map"),
```

This means the Haskell port will proceed with a YAML mapping object where it expects a string, leading to confusing downstream failures (e.g., trying to use `{"staging":"profile-a","prod":"profile-b"}` as a profile name). The Rust behavior of returning an early, clear error is correct.

Additionally, Rust validates that the resolved value is a string (`Some(_) => bail!("must map environments to strings")`), while Haskell accepts any value type.

### H-2: TE.decodeUtf8 (partial) used on arbitrary file content

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Cfn/TemplateLoader.hs` line 165

```haskell
loadFileContent :: FilePath -> IO Text
loadFileContent path = do
  bytes <- BS.readFile path
  pure (TE.decodeUtf8 bytes)
```

`TE.decodeUtf8` throws an exception on invalid UTF-8. If a user points a CloudFormation template path at a file with invalid UTF-8 (e.g., a binary file by accident, or a file with Latin-1 encoding), this will produce an unhandled exception with a confusing error message. Should use `TE.decodeUtf8'` (the safe variant) and return a proper error.

Other uses of `TE.decodeUtf8` (in `Render.hs`, `Demo.hs`) on file content from `BL.readFile` have the same issue but are less critical since they operate on template files that the user explicitly passes.

### H-3: NTP time arithmetic uses Word32 subtraction that can silently underflow

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Aws/Timing.hs` lines 119-128

```haskell
parseNtpResponse bs
  | otherwise =
      let secs = getWord32 bs 40
          ntpToUnixOffset :: Word32
          ntpToUnixOffset = 2208988800
          unixSecs = fromIntegral (secs - ntpToUnixOffset) :: Double
```

`secs - ntpToUnixOffset` is a `Word32` subtraction. If the NTP server returns a timestamp before Unix epoch (e.g., a malformed response), this underflows silently (wrapping around) and produces an absurd time value. While the NTP epoch (1900) predates Unix epoch (1970), a corrupt or spoofed NTP response could contain a small `secs` value.

The function does check `BS.length bs < 48` but does not validate the `secs` value range. Given that NTP is used for write operations and clock drift detection, a wildly wrong time could lead to subtle ordering issues in event timestamps.

Mitigation: validate that `secs >= ntpToUnixOffset` before subtraction, return `Nothing` otherwise.

### H-4: HTTP import loader creates a new Manager per import

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Imports/Loaders/Http.hs` line 54

```haskell
loadHttpImport location = do
  mgr <- newManager defaultManagerSettings
```

Each HTTP import creates a fresh `Manager` (and its underlying connection pool). If a template has multiple HTTP imports, this wastes resources and prevents connection reuse. The `Manager` should be created once and threaded through the import loading pipeline, or at minimum use `newManager tlsManagerSettings` for HTTPS support.

Additionally, `defaultManagerSettings` does not support HTTPS. If a user imports from `https://` URLs, the HTTP loader will fail. The function accepts both `http://` and `https://` URLs based on the type parsing, but `defaultManagerSettings` lacks TLS support.

### H-5: Spinner thread not properly cleaned up on exception

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Output/Renderers/Interactive/Sections.hs` (spinner usage)

The spinner is started as a background thread (via `async` or `forkIO`) but there is no `bracket` or `finally` pattern to ensure `spinnerFinishAndClear` is called if the main operation throws an exception. If a network error occurs during polling, the spinner animation continues writing to the terminal, potentially corrupting the error output.

## Medium Findings

### M-1: lookupO is O(n) linear scan; used in hot paths

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/OValue.hs` lines 106-109

```haskell
lookupO :: Text -> [(Text, OValue)] -> Maybe OValue
lookupO k kvs = case [v | (k', v) <- kvs, k' == k] of
  (v:_) -> Just v
  []    -> Nothing
```

This is a linear scan over association lists. For large CloudFormation templates with many keys per mapping, this is O(n) per lookup. The resolver calls `lookupO` in `resolveDotPathO`, `applyDotQueryValidated`, `resolveMapListToHash`, `resolveGroupBy`, and `resolveMapValues`, which can compound to O(n*m) for nested operations.

While this matches the ordered-key design goal, a `Map Text OValue` lookup alongside the list would give O(log n) lookup while preserving insertion order for output. Not critical for typical template sizes but could matter for templates with hundreds of resources.

### M-2: mergeOObjects uses elem on list, O(n*m) merge

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Resolver.hs` lines 599-609

```haskell
mergeOObjects (OObject base) overlay =
  let updatedBase = map (\(k, v) -> case lookup k overlay of ...) base
      baseKeys = map fst base
      newKeys = filter (\(k, _) -> k `notElem` baseKeys) overlay
  in OObject (updatedBase ++ newKeys)
```

Both `lookup k overlay` (line 602) and `k `notElem` baseKeys` (line 607) are O(n) scans, making the overall merge O(n*m). For `!$merge` with many source objects or large objects, this could be slow. A `Set` for `baseKeys` would reduce to O(n + m * log n).

### M-3: emitMultilineString uses `init` which is partial on empty lists

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Emitter.hs` lines 55-61

```haskell
emitMultilineString s =
  let lns = T.splitOn "\n" s
      hasTrailingNewline = T.isSuffixOf "\n" s
      bodyLines = if hasTrailingNewline then init lns else lns
```

`init` is a partial function that throws on empty lists. `T.splitOn "\n" s` always returns at least one element (never empty), so `init` won't be called on `[]`. However, this relies on `T.splitOn` invariants. The CLAUDE.md rules say "No partial functions" -- should use a safe alternative even though it's technically safe here.

Same pattern at line 215 (`emitMultilineStringIndented`).

### M-4: resolveEnvMaps should run before YAML preprocessing

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackArgsLoader.hs` lines 76-82

The Haskell port preprocesses the argsfile YAML first (resolving imports, handlebars, etc.) and then resolves environment maps. The Rust version does the same ordering. However, this means imports (`$imports`) use the pre-env-resolution values. If an import location contains `{{Profile}}` and Profile is an environment map, the handlebars interpolation would receive the map object instead of the resolved string.

This is actually a shared issue with Rust (same ordering), but worth noting as a design-level issue that affects both ports.

### M-5: `buildEnvValues` hardcodes us-east-1 as default region

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackArgsLoader.hs` line 170

```haskell
buildEnvValues env operation aws =
  let region = fromMaybe "us-east-1" (awsRegion aws)
```

This injects `us-east-1` into `$envValues.region` when no region is configured. However, `resolveRegion` in `Config.hs` now errors if no region is configured. So the `$envValues.region` will show `us-east-1` while the actual operation will fail with a region error. The fallback should probably be `""` or the function should propagate the absence.

### M-6: HTTP parseByExtension treats YAML same as JSON for HTTP imports

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Imports/Loaders/Http.hs` lines 120-123

```haskell
parseByExtension ext content rawBytes
  | ext `elem` [".yaml", ".yml"] = parseJsonOrString rawBytes content
  | ext == ".json"                = parseJsonOrString rawBytes content
```

For HTTP imports, `.yaml` and `.yml` files are parsed as JSON (not YAML). This means YAML features not valid in JSON (like anchors, multi-line strings, comments) would fail to parse and fall back to a plain string. The File loader at `File.hs:221` correctly uses `parseYamlToValue` for YAML extensions. This is likely an intentional simplification (HTTP imports may not want the full YAML parser overhead) but could surprise users.

### M-7: No size limit on S3 object fetch

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Imports/Loaders/S3.hs` lines 66-70

The HTTP loader enforces a 10MB size limit (`httpMaxResponseBytes`), but the S3 loader reads the entire object into memory without any size cap:

```haskell
fetchS3Object awsEnv bucket key = runResourceT $ do
  let req = GO.newGetObject bucket key
  resp <- Amazonka.send awsEnv req
  chunks <- AmazonkaData.sinkBody resp.body CL.consume
  pure (BS.concat chunks)
```

A large S3 object (hundreds of MB) referenced via `$imports` could cause OOM. Should enforce a reasonable size limit, especially since these objects are loaded into memory and parsed as text.

## Low / Info Findings

### L-1: Redundant detectCapabilities call in OutputDispatch

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Output/Manager.hs` lines 38, 65-66

The code calls `detectCapabilities` once at line 38, then `newInteractiveRenderer` internally calls it again. Comment at line 65 acknowledges: "This is harmless (cheap I/O) but redundant." Could pass the already-detected capabilities to avoid the redundant system calls.

### L-2: oValuesEqual has unnecessary special case

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Yaml/OValue.hs` lines 87-89

```haskell
oValuesEqual (ONumber a) (ONumber b) = a == b
oValuesEqual a b = a == b
```

The `ONumber` case is redundant -- `Scientific` already has `Eq` which does the same comparison. The derived `Eq` instance for `OValue` handles this. The function exists only to be explicit, but it's misleading because it suggests there's something special about number comparison.

### L-3: Shell type detection could handle uppercase/paths

**File:** `/home/tavis/src/iidy-hs/app/Main.hs` lines 444-447

```haskell
detectShellType "zsh"  = ShellZsh
detectShellType "fish" = ShellFish
detectShellType _      = ShellBash
```

The `SHELL` env var is processed with `reverse $ takeWhile (/= '/') (reverse s)` which extracts the basename, but doesn't lowercase it. `/usr/bin/Zsh` on some systems would fall through to Bash. Minor edge case.

### L-4: `uuid` dependency only used in executable, not library

**File:** `/home/tavis/src/iidy-hs/iidy-hs.cabal` line 166

The `uuid` package is correctly only in the executable section, but the `memory` package (line 133) in the library is used only in `ClientReqToken.hs` for `Data.ByteArray`. This is a transitive dep of `crypton` anyway, so it's harmless but could be noted.

### L-5: `getStrList` silently drops non-string array elements

**File:** `/home/tavis/src/iidy-hs/src/Iidy/Cfn/StackArgsLoader.hs` lines 245-248

```haskell
getStrList obj key = case KM.lookup (Key.fromText key) obj of
  Just (Array arr) -> Just [t | String t <- foldr (:) [] arr]
  _                -> Nothing
```

The list comprehension `[t | String t <- ...]` silently skips non-string elements. If a Capabilities list contains an integer or boolean by mistake, it will be silently dropped rather than reported as an error. The Rust version uses `serde` deserialization which would error on type mismatches.

## Rust Parity Spot-Check

### Modules checked:
1. **SSM loader** (`Ssm.hs` vs `ssm.rs`): Parsing logic equivalent. Both use `splitn(2, ':')` semantics. Haskell uses `breakOnEnd` which has different edge case behavior for colons in parameter paths -- verified that both handle `ssm:/path/with:colon` correctly (treats final colon segment as format only if it's "json" or "yaml").

2. **Stack args loader** (`StackArgsLoader.hs` vs `stack_args.rs`): Field set matches 1:1 (21 fields). Environment map resolution order identical. `$envValues` injection structure matches. **Gap found:** error handling for missing environment in env maps (H-1 above).

3. **SSM path loader** (`SsmPath.hs` vs `ssm.rs`): Pagination bug in both (C-1). Result structure equivalent. Key stripping logic matches.

4. **Template loader** (`TemplateLoader.hs` vs Rust `template_loader.rs`): `render:` prefix, S3 URL detection, `$imports:` check all match. Size limit enforcement matches.

5. **Context / terminal statuses** (`Context.hs` vs `is_terminal_status.rs`): 14 terminal statuses match. `UPDATE_FAILED` correctly excluded. Documentation is thorough.

### Gaps found:
- H-1: Missing error on unresolved env map environment (significant behavioral divergence)
- C-1: Missing pagination in SSM path operations (shared bug with Rust)
- The `resolveEnvMap` in Rust also validates that the resolved value is a String; Haskell does not

## Test Coverage Assessment

### Well-covered areas:
- YAML parsing and emission (37 snapshot tests + property tests)
- Error display and classification (49 error fixture tests + 11 re-enabled)
- Handlebars engine and helpers
- JMESPath queries
- JSON Schema validation
- CLI parser
- Stack operations (mock polling, event formatting)
- Output renderers (interactive + JSON, 26 OutputData types)
- Changeset helpers
- Template hash and S3 URL parsing

### Areas needing more tests:
1. **Stack args env map resolution** -- no tests for the error case where environment is missing from a map. The current silent-fallthrough behavior (H-1) has no test asserting this behavior.
2. **TemplateLoader render: path** -- no tests for the `render:` prefix path through `loadCfnTemplate`. This is a complex path (parse, inject env values, preprocess, emit, size check).
3. **HTTP loader HTTPS support** -- no tests verifying that HTTPS URLs actually work (they likely don't without TLS manager settings).
4. **SSM path pagination** -- tests only cover single-page results; no test verifying multi-page fetches.
5. **NTP response parsing edge cases** -- tests exist for `parseNtpResponse` and `getWord32` but not for underflow/overflow scenarios with corrupt timestamps.
6. **Import cycle detection** -- `ImportStack` has the cycle detection logic but I found no dedicated test for the `pushImport` cycle error path.
7. **File import with non-UTF-8 content** -- File loader uses `TE.decodeUtf8'` (safe), but TemplateLoader uses `TE.decodeUtf8` (partial). No test covers the difference.
