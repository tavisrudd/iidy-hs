# Audit: 03-import-system.md

Audited 2026-03-05 against Haskell codebase (Imports/Types.hs, Imports/Manifest.hs, Imports/ContentParsing.hs, Imports/Loaders/Dispatch.hs, Loaders/File.hs, Loaders/Cfn.hs, Loaders/Ssm.hs, Loaders/Random.hs, Loaders/Http.hs, Loaders/S3.hs, Engine.hs).

## Accuracy Issues

### 1. CFN sub-types divergence notice is outdated (US-03-008)
**Requirement says:** "Only `cfn:output:stackName/Key` (single output) is implemented."
**Code (Cfn.hs:57-68):** All 6 sub-types are fully implemented: output, export, parameter, tag, resource, stack.
**Fix:** Remove divergence notice. Mark all 6 as specified behavior.

### 2. SSM divergence notice is outdated (US-03-009)
**Requirement says:** "`:json` and `:yaml` format suffixes for `ssm:` are now implemented. The `ssm-path:` sub-type is not yet implemented."
**Code (Ssm.hs):** Both `loadSsmImport` and `loadSsmPathImport` are fully implemented with format suffix support and pagination.
**Fix:** Remove divergence notices.

### 3. Filehash divergence notice is outdated (US-03-005)
**Requirement says:** "The `$imports` loader for `filehash:` and `filehash-base64:` is a known divergence; see Technical Context above. The Handlebars helpers work; only the `$imports` loader is missing."
**Code (File.hs:63-101):** `loadFilehashImport` is fully implemented with directory hashing, optional file support, and base64 encoding.
**Fix:** Remove divergence notice. Document the directory hashing algorithm.

### 4. Random word list counts (US-03-004)
**Requirement says:** "31 adjectives, 30 nouns"
**Code (Random.hs:54-84):** 29 adjectives (red through slow).
**Code (Random.hs:87-117):** 29 nouns (cat through stream).
Actually let me recount carefully:
- Adjectives: red, blue, green, yellow, purple, orange, silver, golden, crystal, cosmic, electric, swift, calm, bold, warm, cool, bright, dark, light, wild, quiet, loud, sharp, smooth, rough, soft, hard, quick, slow = 29
- Nouns: cat, dog, fox, wolf, bear, hawk, river, mountain, forest, ocean, cloud, star, moon, sun, storm, wind, rain, tree, stone, flame, wave, leaf, seed, bridge, tower, gate, path, road, stream = 29
**Fix:** Update to "29 adjectives, 29 nouns" and "29 x 29 = 841 possible combinations".

### 5. HTTP size limit claim (US-03-007)
**Requirement says:** "Extremely large responses: no size limit is enforced"
**Code (Http.hs:49-50, Constants.hs:46-47):** `httpMaxResponseBytes = 10 * 1024 * 1024` (10 MB), enforced during streaming via `readWithLimit`. Also `httpTimeoutSeconds = 30`.
**Fix:** Document: 30-second response timeout, 10 MB maximum body size, enforced during streaming.

### 6. S3 size limit not mentioned (US-03-006)
**Code (S3.hs:86-87):** `s3MaxResponseBytes = httpMaxResponseBytes` (10 MB), enforced during streaming.
**Fix:** Document the same 10 MB limit applies to S3.

### 7. S3 and HTTP parse failures: strict, not lenient
**Requirement (US-03-007):** "YAML and JSON parse failures fall back to raw string."
**Code (S3.hs:59, Http.hs:74):** Both use `parseByExtensionStrict` which returns `ImportError` on parse failure, NOT falling back to string.
**Fix:** S3 and HTTP are strict. Only file imports fall back to string on YAML/JSON parse failure. Wait -- actually looking at ContentParsing.hs more carefully, `parseByExtensionStrict` returns `Left ImportError` on parse failure. But the file loader ALSO uses `parseByExtensionStrict`. Let me re-check... Yes, File.hs:44 also uses `parseByExtensionStrict`. So file imports are ALSO strict for YAML/JSON.

Actually wait -- the requirement for US-03-001 says "YAML parse failure falls back to injecting the raw text as a string (not an error)". But the code uses `parseByExtensionStrict` everywhere. The "strict" variant does NOT fall back. There IS a `parseByFormatSuffixLenient` but it's only used by SSM-path.

**Revised fix:** The file loader does NOT have YAML/JSON fallback. All extension-dispatched parsing (file, S3, HTTP) uses strict parsing. Only SSM-path uses lenient parsing. Update US-03-001 to remove the fallback claim.

## Missing from Requirements

### 8. Filehash directory hashing algorithm
Not documented anywhere. Algorithm:
1. Recursively list all files under the directory (not directories themselves)
2. Sort file paths lexicographically
3. SHA256-hash each file's raw bytes individually
4. Join all hex hashes with commas
5. SHA256-hash the resulting comma-joined string
6. Return the final hash (hex or base64)

### 9. Import type dispatch and security gate logic
The dispatch logic (Dispatch.hs) has three layers not documented:
1. `parseImportType` classifies and enforces remote security
2. `withRemote` gates S3 and HTTP behind `--no-remote-imports`
3. `withAwsEnv` gates CFN, SSM, SSM-path, S3 behind credential availability
CFN/SSM are NOT blocked by `--no-remote-imports` because they use IAM auth, not open HTTP.

### 10. Content parsing dispatch matrix
Four parsing modes exist but are not documented:
- `parseByExtensionStrict`: file, S3, HTTP (errors on parse failure)
- `parseByFormatSuffix`: SSM single (errors on parse failure)
- `parseByFormatSuffixLenient`: SSM-path (falls back to string)
- No parsing: env, git, random (always return strings)

### 11. Recursive import preprocessing
When an imported document contains `$imports` or `$defs`, it is re-parsed to AST and recursively preprocessed with its own environment. Custom resource templates registered inside the imported document are NOT exported to the parent.

### 12. ImportRecord type
```
ImportRecord { irKey :: Maybe Text, irFrom :: Text, irImported :: Text, irSha256Digest :: Text }
```
SHA256 computed from raw imported text content.

## Completeness Assessment

| Section                    | Status           | Notes                                                   |
|----------------------------|------------------|---------------------------------------------------------|
| Overview                   | NEEDS_UPDATE     | Outdated divergence notices                             |
| US-03-001: File imports    | INACCURATE       | Claims YAML/JSON fallback; code is strict               |
| US-03-002: Env imports     | COMPLETE         | Accurate                                                |
| US-03-003: Git imports     | COMPLETE         | Accurate                                                |
| US-03-004: Random imports  | INACCURATE       | Wrong word counts (29/29, not 31/30)                    |
| US-03-005: Filehash        | OUTDATED         | Implemented; divergence notice wrong; missing algorithm  |
| US-03-006: S3 imports      | INACCURATE       | Missing 10 MB size limit; strict parsing                |
| US-03-007: HTTP imports    | INACCURATE       | Claims no size limit; actually 10 MB + 30s timeout      |
| US-03-008: CFN imports     | OUTDATED         | All 6 sub-types implemented; divergence notice wrong    |
| US-03-009: SSM imports     | OUTDATED         | ssm-path implemented; divergence notice wrong           |
| US-03-010: Security model  | COMPLETE         | Accurate                                                |
| US-03-011: Cycle detection | COMPLETE         | Accurate                                                |
| US-03-012: HB interpolation| COMPLETE         | Accurate                                                |
