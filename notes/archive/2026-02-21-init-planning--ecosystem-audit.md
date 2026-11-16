# Haskell Ecosystem Audit for iidy Port

**Date:** 2026-02-21
**Source:** `/home/tavis/src/iidy/Cargo.toml` (iidy 1.0.0, edition 2024)

This audit maps every external Rust crate dependency to its Haskell equivalent,
verifying existence on Hackage, maintenance status, and API coverage.

---

## Summary

- **Total Rust crates (runtime):** 42
- **Total Rust crates (dev):** 5
- **Green (direct equivalent exists, actively maintained):** 33
- **Yellow (equivalent exists, needs attention):** 8
- **Red (significant gap, requires custom work):** 3

---

## Runtime Dependencies

### AWS SDK

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `aws-config` | `amazonka` (core) | 2.0 | 2023-07-27 (rev 2024-05-13) | GREEN | Auth, region, retry config all handled by core `amazonka` |
| `aws-sdk-cloudformation` | `amazonka-cloudformation` | 2.0 | 2023-07-27 (rev 2024-05-13) | GREEN | Full CloudFormation API: stacks, changesets, events, waiters |
| `aws-sdk-kms` | `amazonka-kms` | 2.0 | On Hackage | GREEN | KMS encrypt/decrypt/key management |
| `aws-sdk-s3` | `amazonka-s3` | 2.0 | On Hackage | GREEN | Full S3 API |
| `aws-sdk-sns` | `amazonka-sns` | 2.0 | On Hackage | GREEN | SNS publish/subscribe |
| `aws-sdk-ssm` | `amazonka-ssm` | 2.0 | On Hackage | GREEN | SSM Parameter Store get/put |
| `aws-sdk-sts` | `amazonka-sts` | 2.0 | On Hackage | GREEN | STS AssumeRole, GetCallerIdentity |
| `aws-smithy-types` | (part of `amazonka`) | -- | -- | GREEN | Smithy types abstracted by amazonka |
| `aws-types` | (part of `amazonka`) | -- | -- | GREEN | Region, credentials types in core |
| `aws-credential-types` | (part of `amazonka`) | -- | -- | GREEN | Credential providers in core amazonka |

**AWS verdict:** All 7 AWS services used by iidy (CloudFormation, S3, SSM, STS, KMS, SNS + config/types) have corresponding `amazonka-*` packages. The amazonka 2.0 release is auto-generated from AWS service descriptions and covers the full API surface. GHC 8.10.7+ supported. The lens-heavy API is idiomatic Haskell but different from the Rust builder pattern.

---

### Serialization / Data Formats

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `serde` + `serde_json` | `aeson` | 2.2.x | Actively maintained | GREEN | De facto standard JSON library; derives via GHC Generics or TH |
| `serde_yaml` | `yaml` / `HsYAML` | 0.11.11.2 / 0.2.1.5 | 2023-07-01 / 2025-03-11 | GREEN | `yaml` wraps libyaml via C FFI; `HsYAML` is pure Haskell YAML 1.2. Both integrate with aeson. |
| `yaml-rust` | `HsYAML` | 0.2.1.5 | 2025-03-11 | GREEN | HsYAML provides event-level round-tripping with comment/anchor preservation, matching yaml-rust's low-level control |
| `jsonschema` | **hjsonschema** / `aeson-schema` | 1.10.0 / 0.4.2.0 | 2020-05-01 / 2020-04-09 | YELLOW | **hjsonschema is DEPRECATED** and only supports Draft 4. No Haskell library supports Draft 7 or 2020-12. See [Gap #1]. |

---

### Template Engines

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `handlebars` | `mustache` / `stache` | 2.4.3.1 / 2.3.4 | 2025-05-11 / 2023-06-23 | YELLOW | Mustache is a subset of Handlebars. `mustache` pkg is actively maintained. Handlebars helpers/block helpers would need custom implementation. See [Gap #2]. |

---

### Tree-sitter (YAML Location Tracking)

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `tree-sitter` | `tree-sitter` (Haskell bindings) | 0.9.0.3 | 2022-04-12 | YELLOW | **Marked UNSTABLE** by maintainers. GitHub repo (tree-sitter/haskell-tree-sitter) last commit 2024-09-23. Provides Parser, Node, Cursor, Tree modules via C FFI. |
| `tree-sitter-yaml` | **NONE** | -- | -- | RED | **No Haskell tree-sitter-yaml package exists on Hackage or in haskell-tree-sitter repo.** The C grammar exists at ikatyang/tree-sitter-yaml. See [Gap #3]. |

---

### CLI / Argument Parsing

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `clap` + `clap_complete` | `optparse-applicative` | 0.19.0.0 | 2025-06-03 | GREEN | Mature, well-maintained. Supports subcommands, completions (via `optparse-applicative-completions` or shell generation). Derive-style via `optparse-generic`. |

---

### Terminal UI / Output

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `ratatui` | `brick` | 2.10 | 2025-10-02 (rev 2026-01-21) | GREEN | Declarative TUI. Widgets: lists, tables, borders, progress bars. Built on vty. Actively maintained by Jonathan Daugherty. Feature parity is strong. |
| `crossterm` | `vty` / `vty-crossplatform` | 6.5 | 2025-10-02 | GREEN | Low-level terminal I/O: input events, raw mode, cursor. Unix + Windows via vty-crossplatform. |
| `owo-colors` + `anstyle` | `ansi-terminal` | 1.1.5 | 2025-12-26 | GREEN | ANSI SGR codes: 256-color, RGB, bold/italic/underline. Actively maintained. |
| `indicatif` | `terminal-progress-bar` / `ascii-progress` | 0.4.2 | 2023-06-10 | YELLOW | Less feature-rich than indicatif (no spinners, multi-bar). Progress bars work. Spinners would need custom code or brick integration. |
| `textwrap` | `word-wrap` | 0.5 | 2021-09-25 | GREEN | Word-wrapping with configurable settings. Simpler than textwrap but sufficient. |
| `terminal_size` | `terminal-size` | 0.3.4 | On Hackage | GREEN | `System.Console.Terminal.Size` -- get width/height. |
| `atty` | `System.IO.hIsTerminalDevice` | (base) | -- | GREEN | Built into GHC `base` library. No external dep needed. |

---

### Async / Concurrency

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `tokio` | GHC RTS + `async` + `stm` | (base/async) | Actively maintained | GREEN | GHC's green threads + `async` library + STM provide equivalent concurrency. No special runtime needed -- Haskell is concurrent by default. |
| `async-trait` | (not needed) | -- | -- | GREEN | Haskell typeclasses are already polymorphic over monads; no equivalent needed. |
| `once_cell` | `Data.IORef` / `MVar` / `unsafePerformIO` | (base) | -- | GREEN | Lazy evaluation + IORef covers this. |

---

### Error Handling

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `anyhow` | `Control.Exception` / `unliftio` | (base) | -- | GREEN | Haskell exceptions + `SomeException` provide similar error boxing. |
| `thiserror` | (Haskell ADTs + `Exception` class) | (base) | -- | GREEN | Define error types as ADTs, derive `Exception`. More natural in Haskell. |

---

### HTTP / Networking

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `reqwest` | `req` / `http-conduit` / `wreq` | 3.13.4 | 2024-09-29 (rev 2026-01-18) | GREEN | `req` is type-safe, ergonomic. `http-conduit` for streaming. Both support JSON, TLS. |
| `url` | `network-uri` | (in base ecosystem) | -- | GREEN | URI parsing/manipulation in `network-uri`. |
| `urlencoding` | `http-types` (urlEncode/urlDecode) | -- | -- | GREEN | URL encoding utilities in `http-types`. |
| `ntp` | `hsntp` / custom | 0.1 | **2008-03-09** | RED | **hsntp is from 2008 and almost certainly broken.** `ntp-control` exists but is for NTP daemon control, not time sync. See [Gap #4]. |

---

### Cryptography / Hashing

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `sha2` | `cryptohash-sha256` / `cryptonite` | Actively maintained | -- | GREEN | `cryptonite` (or its successor `crypton`) provides SHA-256 and more. |
| `base64` | `base64-bytestring` | Actively maintained | -- | GREEN | Standard base64 encoding/decoding. |
| `hex` | `base16-bytestring` | Actively maintained | -- | GREEN | Hex encoding/decoding. |

---

### Utilities

| Rust Crate | Haskell Equivalent | Version | Last Upload | Status | Notes |
|---|---|---|---|---|---|
| `regex` | `regex-tdfa` / `regex-pcre` | Actively maintained | -- | GREEN | `regex-tdfa` for POSIX extended; `regex-pcre` for Perl-compatible. |
| `similar` | `Diff` | 1.0.2 | 2024-11-15 | GREEN | Myers diff algorithm. Pure Haskell. Actively maintained. |
| `jmespath` | **jamespath-hs** (GitHub only) | -- | Not on Hackage | RED | **Not published to Hackage. GitHub repo (gcapizzi/jamespath-hs) has 3 stars, unknown maintenance. No official Haskell JMESPath on jmespath.org.** See [Gap #5]. |
| `uuid` | `uuid` | Actively maintained | -- | GREEN | `Data.UUID` / `Data.UUID.V4` on Hackage. |
| `rand` | `random` | (base ecosystem) | -- | GREEN | `System.Random` in base; `random` package for more features. |
| `heck` | `casing` | 0.1.4.1 | 2019-09-05 | YELLOW | Supports camelCase, PascalCase, kebab-case, snake_case. Older but functional. |
| `glob` | `Glob` | 0.10.2 | 2021-11-10 | GREEN | POSIX glob matching. `filepattern` is a modern alternative. |
| `smallvec` | `vector` (Data.Vector) | Actively maintained | -- | GREEN | Haskell's `vector` package. No need for small-buffer optimization due to GHC's memory model. |
| `tempfile` | `temporary` | 1.3 | Actively maintained | GREEN | `System.IO.Temp` for temp files/directories. |
| `log` + `env_logger` | `monad-logger` / `co-log` / `katip` | Actively maintained | -- | GREEN | Multiple mature logging frameworks. |
| `portable-pty` | `posix-pty` | 0.2.2 | 2020-07-03 | YELLOW | POSIX only (no Windows). Functional but not recently updated. For iidy's demo feature this is likely sufficient on Linux/macOS. |
| `chrono` | `time` | (base ecosystem) | -- | GREEN | `Data.Time` in base provides date/time parsing, formatting, arithmetic. |

---

## Dev Dependencies

| Rust Crate | Haskell Equivalent | Version | Status | Notes |
|---|---|---|---|---|
| `mockito` | `hspec` + custom mocks / `servant-mock` | -- | GREEN | Haskell prefers typeclass-based mocking (MTL style) rather than HTTP interception. For AWS, use `amazonka`'s mock mode or `servant-mock`. |
| `tokio-test` | (not needed) | -- | GREEN | GHC RTS handles async testing natively. `hspec` + `async` suffice. |
| `proptest` | `QuickCheck` / `hedgehog` | Actively maintained | GREEN | `hedgehog` has excellent shrinking. `QuickCheck` is the classic. Both integrate with hspec/tasty. |
| `insta` | `tasty-golden` / `hspec-golden` | Actively maintained | GREEN | Golden/snapshot testing. `tasty-golden` is the standard approach. |
| `criterion` | `criterion` / `tasty-bench` | 1.6.4.1 | GREEN | `criterion` is the gold standard for Haskell benchmarks. Same name, same purpose. |

---

## Gap Analysis

### Gap #1: JSON Schema Validation (YELLOW - Workaround Available)

**Problem:** The Rust `jsonschema` crate supports Draft 7+. The best Haskell library (`hjsonschema`) is **deprecated** and only supports Draft 4. Other libraries (`aeson-schema`, `json-schema`) are also stale (last updated 2020 or earlier).

**Impact:** iidy uses JSON Schema to validate `$params` in custom resource templates. This is a bounded use case -- likely validating a handful of schema keywords (type, required, properties, additionalProperties).

**Proposed solution:**
1. **Option A:** Implement a minimal Draft 7 validator (~200-400 LOC) covering only the keywords iidy actually uses. This is feasible because iidy's schemas are simple parameter validation, not arbitrary JSON Schema.
2. **Option B:** FFI to a C JSON Schema library (e.g., `ocilib` or a JSON Schema C validator). More complex but gives full compliance.
3. **Option C:** Use `hjsonschema` as-is if the schemas only use Draft 4 features (likely true for parameter validation).

**Recommendation:** Option A. Write a minimal validator.

---

### Gap #2: Handlebars vs Mustache (YELLOW - Partial Gap)

**Problem:** The Rust `handlebars` crate supports Handlebars syntax including helpers, block helpers, and partials. Haskell has excellent Mustache libraries (`mustache` 2.4.3.1, actively maintained as of 2025-05-11) but Mustache is a strict subset of Handlebars.

**Impact:** Need to audit which Handlebars features iidy actually uses. If only `{{variable}}`, `{{#if}}`, `{{#each}}`, and `{{> partial}}`, then Mustache covers it. If custom helpers are used, they need reimplementation.

**Proposed solution:**
1. Audit iidy's template usage to determine if Mustache suffices.
2. If Handlebars-specific features are needed, extend `mustache` or `stache` with custom helper support (~100-300 LOC).

**Recommendation:** Audit first, then decide. Mustache likely suffices.

---

### Gap #3: tree-sitter-yaml Haskell Bindings (RED - Requires FFI Work)

**Problem:** There is **no `tree-sitter-yaml` package** for Haskell. The haskell-tree-sitter repository includes grammars for Go, Haskell, Java, JSON, Python, Ruby, Rust, TypeScript, and others -- but **not YAML**. The base `tree-sitter` Haskell bindings exist (v0.9.0.3) but are marked "unstable."

The C tree-sitter-yaml grammar exists at [ikatyang/tree-sitter-yaml](https://github.com/ikatyang/tree-sitter-yaml) and is well-maintained.

**Impact:** iidy uses tree-sitter for precise YAML source location tracking during preprocessing. This is used for error reporting with exact line/column positions.

**Proposed solutions:**
1. **Option A (Recommended):** Write FFI bindings to the C tree-sitter-yaml grammar. Following the pattern of existing haskell-tree-sitter language packages, this is ~50-100 LOC of FFI boilerplate. The C grammar (`tree_sitter_yaml()`) just needs to be linked and exposed as a `Ptr Language`.
2. **Option B:** Use HsYAML's event-level API which provides source positions (line/column) during parsing. This avoids tree-sitter entirely but gives less granular AST structure.
3. **Option C:** Use the unstable Haskell tree-sitter bindings + write the YAML grammar wrapper. Risk: the "unstable" warning means the API may change.

**Recommendation:** Option B first (HsYAML events have positions), with Option A as a follow-up if more precise AST-level location tracking is needed. The tree-sitter approach is more powerful but the HsYAML event API may be sufficient for error reporting.

---

### Gap #4: NTP Time Synchronization (RED - Minor)

**Problem:** The Haskell `hsntp` package was uploaded in **2008** and is almost certainly non-functional with modern GHC. No actively maintained Haskell NTP client library exists.

**Impact:** iidy uses the `ntp` crate for timing/NTP support. This is likely a minor feature (clock skew detection or timestamp verification).

**Proposed solutions:**
1. **Option A:** Implement a minimal SNTP client (~100 LOC). The SNTP protocol is simple: send a UDP packet to an NTP server, parse the 48-byte response.
2. **Option B:** Shell out to `ntpdate -q` or `sntp` for one-off time checks.
3. **Option C:** Drop the feature if it's non-essential.

**Recommendation:** Option C (drop) or Option A (minimal implementation) depending on how critical this feature is.

---

### Gap #5: JMESPath (RED - Requires Implementation)

**Problem:** There is **no published Haskell JMESPath library on Hackage**. The only implementation (`jamespath-hs` on GitHub) has 3 stars, is not on Hackage, and has unknown maintenance status. The official jmespath.org site lists no Haskell implementation.

**Impact:** iidy uses JMESPath for JSON query filtering. This is a user-facing feature where CloudFormation outputs or parameters can be queried with JMESPath expressions.

**Proposed solutions:**
1. **Option A:** Port the `jamespath-hs` GitHub code, fix it up, and vendor it. It has 126 commits so it may be fairly complete.
2. **Option B:** Implement a JMESPath evaluator from the [specification](https://jmespath.org/specification.html). The spec is well-defined; a basic implementation covering iidy's usage (~500-1000 LOC) is feasible.
3. **Option C:** Use `jsonpath` (Hackage) as an alternative query language. JSONPath is different from JMESPath but serves similar purposes. This would be a user-facing change.
4. **Option D:** FFI to the C or Rust JMESPath library.

**Recommendation:** Option A (evaluate and adopt jamespath-hs) with fallback to Option B.

---

## Package Mapping Quick Reference

| Rust Crate | Haskell Package | Notes |
|---|---|---|
| `atty` | `System.IO.hIsTerminalDevice` (base) | Built-in |
| `clap` | `optparse-applicative` | |
| `clap_complete` | `optparse-applicative` (completions) | Shell completion generation |
| `aws-config` | `amazonka` | Core package |
| `aws-sdk-cloudformation` | `amazonka-cloudformation` | |
| `aws-sdk-kms` | `amazonka-kms` | |
| `aws-sdk-s3` | `amazonka-s3` | |
| `aws-sdk-sns` | `amazonka-sns` | |
| `aws-sdk-ssm` | `amazonka-ssm` | |
| `aws-sdk-sts` | `amazonka-sts` | |
| `aws-smithy-types` | `amazonka` | Absorbed into core |
| `aws-types` | `amazonka` | Absorbed into core |
| `aws-credential-types` | `amazonka` | Absorbed into core |
| `chrono` | `time` (base) | |
| `regex` | `regex-tdfa` | |
| `serde` | `aeson` + GHC Generics | |
| `serde_yaml` | `yaml` / `HsYAML` | |
| `serde_json` | `aeson` | |
| `jsonschema` | *Minimal custom validator* | Gap #1 |
| `yaml-rust` | `HsYAML` | |
| `jmespath` | *Port jamespath-hs or write custom* | Gap #5 |
| `similar` | `Diff` | |
| `tree-sitter` | `tree-sitter` (Haskell bindings) | Unstable |
| `tree-sitter-yaml` | *Write FFI wrapper or use HsYAML events* | Gap #3 |
| `anyhow` | `Control.Exception` | |
| `thiserror` | Haskell ADTs + `Exception` | |
| `tokio` | GHC RTS + `async` + `stm` | |
| `handlebars` | `mustache` / `stache` | Partial gap #2 |
| `reqwest` | `req` / `http-conduit` | |
| `sha2` | `crypton` / `cryptohash-sha256` | |
| `url` | `network-uri` | |
| `urlencoding` | `http-types` | |
| `async-trait` | (not needed) | Typeclasses are polymorphic |
| `base64` | `base64-bytestring` | |
| `hex` | `base16-bytestring` | |
| `rand` | `random` | |
| `uuid` | `uuid` | |
| `smallvec` | `vector` | |
| `heck` | `casing` | |
| `glob` | `Glob` / `filepattern` | |
| `ntp` | *Write minimal SNTP or drop* | Gap #4 |
| `owo-colors` | `ansi-terminal` | |
| `anstyle` | `ansi-terminal` | |
| `indicatif` | `terminal-progress-bar` | Missing spinners |
| `textwrap` | `word-wrap` | |
| `ratatui` | `brick` | |
| `tempfile` | `temporary` | |
| `terminal_size` | `terminal-size` | |
| `crossterm` | `vty` / `vty-crossplatform` | |
| `log` | `monad-logger` / `co-log` | |
| `env_logger` | `monad-logger` / `co-log` | |
| `portable-pty` | `posix-pty` | POSIX only |
| `once_cell` | `IORef` / lazy evaluation | Built-in |

---

## Effort Estimate for Gap Work

| Gap | Estimated LOC | Effort | Priority |
|---|---|---|---|
| #1 JSON Schema (minimal validator) | 200-400 | 1-2 days | Medium |
| #2 Handlebars audit + extension | 0-300 | 0.5-1 day | Low (audit first) |
| #3 tree-sitter-yaml (FFI or HsYAML events) | 50-200 | 0.5-1 day | High |
| #4 NTP (minimal SNTP or drop) | 0-100 | 0-0.5 day | Low |
| #5 JMESPath (port/implement) | 500-1000 | 2-4 days | High |
| **Total gap work** | **750-2000** | **4-8.5 days** | |

---

## Conclusion

The Haskell ecosystem covers **~90% of iidy's dependencies** with mature, actively maintained libraries. The AWS coverage via `amazonka` is comprehensive. The terminal UI story (`brick` + `vty` + `ansi-terminal`) is arguably stronger than Rust's. Core infrastructure (JSON, YAML, HTTP, crypto, CLI parsing) is well-served.

The three significant gaps are:
1. **JMESPath** -- no published Haskell implementation (highest risk, most LOC)
2. **tree-sitter-yaml** -- no Haskell bindings exist, but HsYAML events may substitute
3. **JSON Schema validation** -- deprecated/stale libraries, but minimal validator is feasible

None of these gaps are blockers. All can be resolved with bounded, well-scoped implementation work totaling an estimated 4-8.5 days.
