# Fix HTTP Loader: Manager Reuse + TLS + YAML Parsing (H-4, M-6)

**Severity**: High/Medium
**File**: `src/Iidy/Yaml/Imports/Loaders/Http.hs`

## H-4: New Manager per import + no HTTPS

Line 54: `newManager defaultManagerSettings` creates a fresh connection pool per import
and doesn't support HTTPS.

**Fix**:
1. Switch to `newTlsManager` from `http-client-tls` (or `newManager tlsManagerSettings`)
2. Thread the Manager through the import pipeline OR create it once in a top-level IORef/MVar
3. Check if `http-client-tls` is already a dependency; if not, add it to the cabal file

## M-6: YAML parsed as JSON for HTTP imports

Lines 120-123: `.yaml`/`.yml` extensions use `parseJsonOrString` instead of the YAML parser.
The File loader at `File.hs:221` correctly uses `parseYamlToValue`.

**Fix**: Use the YAML parser for `.yaml`/`.yml` extensions, matching File loader behavior.

## Verification
- `cabal build` zero warnings
- `cabal test` all 972+ tests pass
- Verify `http-client-tls` dep is properly wired
