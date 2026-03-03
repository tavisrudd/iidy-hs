# Code Review Letter Grades -- 2026-03-01

Companion to [2026-03-01-review--fresh-due-diligence.md](2026-03-01-review--fresh-due-diligence.md).

## Revision history

- **v1** (initial): grades based on original findings (972 tests)
- **v2** (updated): re-graded after team fixed C-1, H-1 through H-5, M-3, M-5, M-6, M-7 (995 tests)

## v2 Grades (post-fix)

| #  | Dimension                | Grade  | Justification                                                                                                                                                                                                                                                    |
|----|--------------------------|--------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | Architecture & Design    | A      | Unchanged. Clean 86-module decomposition, well-isolated custom implementations (JMESPath, Handlebars, JSON Schema), sound OValue design. Minor wart: `percentEncode` lives in StackOperations to avoid circular deps, not a shared utility. No regressions introduced by fixes. |
| 2  | Code Quality             | A      | Partial `init` replaced with total `safeInit`. `TE.decodeUtf8` replaced with safe `TE.decodeUtf8'` in TemplateLoader. The `lookupO` O(n) decision is now documented with a crossover analysis comment, making the intentional choice legible. `oValuesEqual` redundancy remains but is harmless. |
| 3  | Correctness              | A-     | All three correctness bugs are fixed: SSM pagination no longer silently truncates (C-1), env-map resolution now errors on missing environments and validates string types matching Rust (H-1), and NTP underflow is guarded. 995 tests with 13 new pagination tests and 6 new env-map tests. Snapshot parity unchanged at 37/37 render and 49/49 error. Remaining gap: `mergeOObjects` O(n*m) is documented-intentional, not a correctness issue. |
| 4  | Security                 | A      | All security gaps closed: HTTPS imports now use `newTlsManager` via a module-level `IORef` (H-4), S3 fetches now enforce the same 10MB cap as HTTP (M-7), and NTP validates the timestamp is post-Unix-epoch before subtraction (H-3). Import security gate, credential handling, regex length cap, and size limits are all intact. |
| 5  | Test Coverage            | A      | 995 tests (+23 since v1). New coverage: 13 SSM pagination tests, 6 env-map error path tests, 3 NTP underflow tests, 1 TemplateLoader UTF-8 test. The previously-flagged gaps are now addressed. Remaining gap: no test for the `render:` prefix template path end-to-end, but that is complex live-code territory. |
| 6  | Rust Parity              | A-     | The two meaningful divergences from Rust are fixed: env-map error handling now matches (H-1) and HTTPS imports now work where Rust's reqwest supported them (H-4). The `$envValues.region` empty-string default (M-5 fix) is a minor remaining mismatch vs Rust's `"us-east-1"` fallback, but is arguably more correct given that region errors are now surfaced explicitly. All documented DIVERGENCES.md entries are intentional and reasonable. |
| 7  | Documentation            | A      | Unchanged. New `lookupO` comment explaining the O(n) crossover analysis adds useful context. `fetchParametersByPath` in both SsmPath and GlobalConfig now has a comment explaining the pagination fix. Module docs, PRDs, and developer docs are all intact. |
| 8  | Build & CI Hygiene       | A+     | Unchanged. Zero warnings, pre-commit `-Werror` + full test suite. 995 tests pass in under 0.3s. The new `Network.HTTP.Client.TLS` import did not introduce a new cabal dep (http-conduit already transitively depends on http-client-tls). |
| 9  | Performance              | B+     | HTTP Manager is now created once and reused (H-4 fix), eliminating per-import connection pool churn. `lookupO` O(n) is retained with documented justification — the crossover analysis shows it is faster than `Map` for real CFN template sizes. `mergeOObjects` O(n*m) remains but is documented-intentional. The S3 size cap adds a `BS.length` call post-concat, which is O(n) in body size but inconsequential relative to the I/O cost. |
| 10 | **Overall**              | **A**  | The team addressed every critical and high finding plus most medium ones with well-targeted fixes and corresponding tests. The codebase is clean, correct, secure, and well-documented. The remaining known issues (M-1/M-2 intentional, `mergeOObjects`, `render:` path test gap) are either justified by analysis or minor. This is production-ready code. |

## v1 Grades (original, for reference)

| #  | Dimension                | Grade  |
|----|--------------------------|--------|
| 1  | Architecture & Design    | A      |
| 2  | Code Quality             | A-     |
| 3  | Correctness              | B+     |
| 4  | Security                 | A-     |
| 5  | Test Coverage            | A-     |
| 6  | Rust Parity              | B+     |
| 7  | Documentation            | A      |
| 8  | Build & CI Hygiene       | A+     |
| 9  | Performance              | B      |
| 10 | **Overall**              | **A-** |
