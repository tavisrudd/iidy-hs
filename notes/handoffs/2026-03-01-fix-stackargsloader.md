# Fix StackArgsLoader: Env Map Error + Region Default (H-1, M-5)

**Severity**: High
**File**: `src/Iidy/Cfn/StackArgsLoader.hs`

## Problem H-1: resolveEnvMaps silently swallows missing environment

Lines 121-128: When an env map doesn't contain the current environment, Haskell leaves
the Object as-is. Rust errors: `bail!("environment '{env}' not found in {key} map")`.

```haskell
Nothing  -> obj  -- env not found, leave as-is  <-- BUG
```

**Fix**: Return an error (Left/throwIO) when the environment key is not found in the map.
Also validate that the resolved value is a String (Rust does this too).

## Problem M-5: buildEnvValues hardcodes us-east-1

Line 170: `fromMaybe "us-east-1" (awsRegion aws)` injects a fake region into
`$envValues.region` while `resolveRegion` now errors on missing region.

**Fix**: Use `fromMaybe "" (awsRegion aws)` or propagate the absence. The empty string
is less misleading than a fake region.

## Verification
- `cabal build` zero warnings
- `cabal test` all 972+ tests pass
- Add test: missing env in env map → error
- Add test: resolved env value must be string
