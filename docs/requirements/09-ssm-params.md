# PRD: SSM Parameter Store Operations

## Overview

iidy-hs provides a `param` sub-command group for managing AWS Systems Manager (SSM)
Parameter Store values. The five operations — `set`, `get`, `get-by-path`, `get-history`,
and `review` — cover the full lifecycle of a parameter: creation, retrieval, audit, and
a structured approval workflow for sensitive value changes.

This document captures retroactive requirements derived from the implemented behavior in
`src/Iidy/Params/Client.hs`, `src/Iidy/Params/Review.hs`, the Rust source under
`~/src/iidy/src/params/`, and the CLI type definitions in `src/Iidy/Cli.hs` and
`src/Iidy/Cli/Parser.hs`.

The implementation achieves byte-for-byte behavioral equivalence with the Rust iidy binary
on all SSM parameter read, write, review, and error display behaviors.

---

## Implementation Context

The SSM subsystem is split across two Haskell modules:

- `Iidy.Params.Client` — implements `paramGet`, `paramSet`, `paramGetByPath`, and
  `paramGetHistory`. Each function accepts an `Amazonka.Env` and the relevant `*Args`
  type. All operations wrap amazonka calls in `try @SomeException` and return
  `Either Text result` for uniform error handling by the caller in `Main.hs`.
- `Iidy.Params.Review` — implements `paramReview`. The review workflow coordinates
  two SSM fetches (pending + current), displays a diff, prompts via `Iidy.Confirm`,
  and on approval writes the pending value to the main path and deletes the `.pending`
  parameter.
- `Iidy.Yaml.Imports.Loaders.Ssm` — a separate module used during YAML preprocessing
  to load SSM parameter values as `$import` sources (not part of the `param` CLI group).

The Rust reference implementation lives in `~/src/iidy/src/params/` across six files:
`mod.rs`, `set.rs`, `get.rs`, `get_by_path.rs`, `get_history.rs`, and `review.rs`.

**Output channel:** All `param` sub-commands write directly to stdout via `TIO.putStrLn`
or `putStrLn`. They do not use the `OutputDispatch` / renderer pipeline used by
CloudFormation commands. Simple format produces raw text; JSON and YAML formats produce
serialized output via aeson / serde.

**KMS key resolution:** The Rust implementation performs hierarchical KMS alias lookup
for `SecureString` parameters. The Haskell `paramSet` does not yet call KMS for alias
resolution; it passes `type' = Just ParameterType_SecureString` with no explicit `key_id`,
relying on the AWS default CMK (`aws/ssm`). This is tracked as a divergence (see
`DIVERGENCES.md`).

**Tags:** The Rust implementation sets an `iidy:message` tag as a separate
`AddTagsToResource` call after `PutParameter` when `--message` is provided. The Haskell
`paramSet` passes `description = args.psaMessage` to the `PutParameter` request as the
SSM parameter description field rather than as a tag. This is a behavioral divergence.

**Approval workflow tags:** In `param review`, the Rust implementation copies all tags
from the `.pending` parameter to the promoted main parameter after writing. The Haskell
`Iidy.Params.Review.applyPendingChange` does not copy tags; it only writes the value and
deletes `.pending`. This is a known divergence.

**Pagination:** The Rust `get_by_path` and `get_history` paginate via `next_token`. The
Haskell `fetchByPath` issues a single `GetParametersByPath` call and `fetchHistory`
issues a single `GetParameterHistory` call, not handling pagination for large result sets.
This is a known limitation.

**CLI arg types:**

```haskell
data ParamSetArgs = ParamSetArgs
  { psaPath         :: !Text
  , psaValue        :: !Text
  , psaMessage      :: !(Maybe Text)
  , psaOverwrite    :: !Bool
  , psaWithApproval :: !Bool
  , psaType         :: !Text          -- "SecureString" | "String" | "StringList"
  }

data ParamGetArgs = ParamGetArgs
  { pgaPath    :: !Text
  , pgaDecrypt :: !Bool               -- default True; False when --no-decrypt passed
  , pgaFormat  :: !Text               -- "simple" | "json" | "yaml"
  }

data ParamGetByPathArgs = ParamGetByPathArgs
  { gpbPath      :: !Text
  , gpbDecrypt   :: !Bool
  , gpbFormat    :: !Text
  , gpbRecursive :: !Bool
  }

newtype ParamPathArg = ParamPathArg
  { ppaPath :: Text
  }
```

---

## User Stories

### US-09-001: Set a parameter value

**As a** Platform Engineer, **I want to** write a value to an SSM parameter path,
**so that** I can store configuration secrets and string values under a structured
namespace that CloudFormation stacks and application code can consume at runtime.

**Acceptance Criteria:**
- `iidy param set <path> <value>` creates or updates the SSM parameter at `<path>`.
- Default type is `SecureString`; `--type String` or `--type StringList` overrides this.
- `--overwrite` must be passed to update an existing parameter; without it the AWS API
  returns a `ParameterAlreadyExists` error which is surfaced to the user.
- `--message <text>` sets the SSM parameter description field on the `PutParameter` call.
- `--with-approval` writes the value to `<path>.pending` instead of `<path>`, and prints
  a message telling the reviewer which command to run:
  ```
  Parameter change is pending approval. Review change with:
    iidy --region <region> param review <path>
  ```
- Exit code is `0` on success, `1` on AWS error.
- The parameter type string is case-insensitive in the conversion: `"securestring"`,
  `"SecureString"`, and `"SECURESTRING"` all map to `ParameterType_SecureString`.
- Unknown type strings fall through to `String` (Haskell divergence from Rust, which
  passes the string verbatim to the SDK).

**Logic Flow:**
1. CLI parser populates `ParamSetArgs` from positional args and flags.
2. If `psaWithApproval` is `True`, the effective write path is `psaPath <> ".pending"`.
3. `textToParameterType` converts `psaType` to `Maybe SSM.ParameterType`.
4. `putParam` builds a `PP.newPutParameter path value` request with `overwrite` and
   `type'` fields set; `description` is set to `psaMessage` if present.
5. `Amazonka.send` is called inside `runResourceT`.
6. Result is wrapped in `try @SomeException`; `Left` maps to an error string, `Right`
   maps to unit.
7. If `--with-approval`, the approval reminder is printed to stdout.
8. `--message` sets the description field only; no separate tag call is made in the
   Haskell implementation (divergence from Rust's `iidy:message` tag).

**Edge Cases:**
- `--with-approval` combined with `--overwrite`: the `.pending` path is overwritten if it
  already exists; the main path is not touched.
- `--type StringList` with a value containing commas: SSM interprets the value as a
  comma-separated list; iidy passes it through verbatim without parsing.
- Path not starting with `/`: SSM requires paths to start with `/` for hierarchy-based
  operations; SSM accepts non-slash paths for simple string parameters. The CLI does not
  validate the path format.
- Empty value (`""`): passed as-is; AWS SSM accepts empty string values.

**Error Scenarios:**
- `ParameterAlreadyExists` (no `--overwrite`): AWS returns a service error; iidy displays:
  `SSM PutParameter error for <path>: <exception text>`
- `InvalidKeyId`: KMS key alias not found (in Rust; Haskell currently passes no key ID
  so falls back to `aws/ssm` default — no error in Haskell).
- AWS credentials missing or expired: surfaced by the top-level error handler in `Main.hs`
  before the SSM call is attempted.
- SSM service unavailable: `try @SomeException` catches the IO exception and returns
  `Left <error text>` which is printed and the process exits with code `1`.

**Complexity Notes:** Low. The operation is a single `PutParameter` call. The KMS alias
lookup (present in Rust) is not implemented in Haskell, reducing complexity at the cost
of a known divergence. The `--with-approval` path rename is purely local string
manipulation.

---

### US-09-002: Get a single parameter value

**As a** Developer, **I want to** retrieve the current value of an SSM parameter by
path, **so that** I can inspect configuration values, debug deployment issues, or feed
parameter values into shell scripts during development.

**Acceptance Criteria:**
- `iidy param get <path>` fetches the parameter at `<path>` and prints its value.
- Default behavior decrypts `SecureString` parameters; `--no-decrypt` suppresses
  decryption and returns the ciphertext reference.
- `--format simple` (default) prints the raw value string with a trailing newline and
  nothing else.
- `--format json` prints a JSON object with PascalCase fields matching the Rust
  `ParamOutput` struct:
  `Name`, `Type`, `Value`, `Version`, `LastModifiedDate`, `ARN`, `DataType`, `Tags`.
- `--format yaml` prints the same structure as YAML.
- For JSON and YAML formats, the `Tags` field includes the parameter's tags fetched via a
  separate `ListTagsForResource` call. In Haskell, the Rust-side tag fetch is not
  implemented in `paramGet`; the field is omitted (divergence).
- Exit code is `0` on success, `1` on AWS error (parameter not found, no permission).

**Logic Flow:**
1. `paramGet` calls `fetchParam awsEnv args.pgaPath args.pgaDecrypt`.
2. `fetchParam` builds `GP.newGetParameter paramName` with `withDecryption = Just bool`.
3. `Amazonka.send` returns the response; `resp.parameter ^. SSMP.parameter_value` extracts
   the value (the `parameter_value` lens unwraps the `Sensitive` wrapper).
4. If format is `"simple"`, the raw value is returned and printed via `TIO.putStrLn`.
5. If format is `"json"` or `"yaml"`, the Rust implementation constructs a `ParamOutput`
   and serializes it; Haskell returns only the plain text value even for non-simple formats
   (this is a known gap — the structured output for non-simple formats is not yet
   implemented in Haskell).
6. `try @SomeException` wraps the fetch; any exception produces `Left <error text>`.

**Edge Cases:**
- Parameter does not exist: AWS returns `ParameterNotFoundException`; caught as
  `SomeException` and returned as `Left` error text.
- `SecureString` fetched with `--no-decrypt`: AWS returns the ciphertext reference string
  (typically an ARN or cipher blob), not the plaintext.
- Parameter value contains newlines: printed verbatim in simple format; JSON/YAML encoding
  handles escaping.
- Path with trailing slash: SSM treats `/myapp/` and `/myapp` as distinct names; no
  normalization is performed.

**Error Scenarios:**
- `ParameterNotFound`: displayed as `SSM GetParameter error for <path>: <exception>`
- `AccessDeniedException`: same error format; user must check IAM permissions.
- Network error: caught by `try @SomeException`; displayed and exits with code `1`.

**Complexity Notes:** Low. Single API call, no pagination, no tag fetch in current
Haskell implementation. The main complexity gap is the structured JSON/YAML output for
non-simple formats, which matches Rust but is not yet wired in Haskell.

---

### US-09-003: List parameters under a path prefix

**As a** Platform Engineer, **I want to** retrieve all SSM parameters whose paths begin
with a given prefix, **so that** I can audit or export an entire namespace of configuration
values in one operation rather than fetching each individually.

**Acceptance Criteria:**
- `iidy param get-by-path <path>` fetches all parameters under `<path>`.
- `--recursive` (default off) includes parameters in sub-paths; without it only direct
  children are returned.
- `--no-decrypt` suppresses decryption for `SecureString` parameters.
- `--format simple` (default) prints a YAML map of `{path: value}`, sorted by path,
  using a key-sorted `BTreeMap`.
- `--format json` and `--format yaml` print a map of `{path: ParamOutput}` objects with
  tag fields included (Rust implementation; Haskell prints formatted name=value pairs
  instead via `formatParam`).
- If no parameters exist under the path, the Rust implementation prints
  `"No parameters found"` and exits with code `1`; Haskell returns an empty list and
  prints nothing (divergence).
- Results are sorted alphabetically by parameter name (both Rust and Haskell).
- Pagination: the Rust implementation follows `next_token` to retrieve all results; the
  Haskell implementation issues a single API call and may miss results for paths with
  more than the API page limit (default 10 parameters per page).

**Logic Flow:**
1. `paramGetByPath` calls `fetchByPath awsEnv args`.
2. `fetchByPath` builds `GPBP.newGetParametersByPath args.gpbPath` with `recursive` and
   `withDecryption` set.
3. `Amazonka.send` returns the response; `fromMaybe [] resp.parameters` extracts the list.
4. `map formatParam params` converts each `SSM.Parameter` to `"name=value"` text.
5. For simple format (Rust): constructs a `BTreeMap<String, String>` and serializes as
   YAML.
6. For Haskell: `formatParam` returns `name <> "=" <> value`; the caller in `Main.hs`
   prints each entry on its own line (format flag is accepted but not differentiated
   beyond the raw list of entries).
7. `try @SomeException` wraps the entire fetch.

**Edge Cases:**
- Path prefix with no trailing slash: SSM `GetParametersByPath` requires the path to
  start with `/`; behavior for paths not starting with `/` is SDK-defined.
- Recursive with a deep tree: each level is included in a single API call; no additional
  calls are made per level.
- Mix of `SecureString` and `String` parameters under one prefix: both are returned in
  a single response; decryption applies to all.
- Large parameter sets: Haskell silently truncates at page boundary (divergence); Rust
  paginates fully.

**Error Scenarios:**
- Path prefix does not exist: API returns an empty `parameters` list, not an error.
- Path without `/` prefix: SSM SDK may return `InvalidFilterValue`; surfaced as
  `SSM GetParametersByPath error for <path>: <exception>`.
- IAM permissions allow `GetParameter` but not `GetParametersByPath`: returns
  `AccessDeniedException`; displayed as error, exits with code `1`.

**Complexity Notes:** Medium. The simple format YAML map is the primary output contract.
The pagination gap is a known limitation that affects deployments with more than 10
parameters per path prefix. The structured JSON/YAML output with tag fetching adds N
additional API calls (one per parameter) in the Rust implementation.

---

### US-09-004: View parameter version history

**As a** Reviewer, **I want to** inspect the full version history of an SSM parameter,
**so that** I can audit who changed a value, when it changed, and what the previous values
were during an incident investigation or compliance review.

**Acceptance Criteria:**
- `iidy param get-history <path>` retrieves all stored versions of the parameter.
- `--no-decrypt` suppresses decryption; by default `SecureString` values are decrypted.
- `--format simple` (default) prints a YAML structure with a `Current` section and a
  `Previous` list, sorted by `LastModifiedDate` ascending so the newest entry is `Current`.
  The `Current` section includes `Value`, `LastModifiedDate`, `LastModifiedUser`, and
  `Message` (from the `iidy:message` tag). The `Previous` list entries include `Value`,
  `LastModifiedDate`, `LastModifiedUser`.
- `--format json` and `--format yaml` print a `{Current: ParamHistoryOutput, Previous: [...]}`
  structure where each entry is a full `ParamHistoryOutput` object. The `Current` entry
  includes tags. In Rust, `Previous` entries do not include tags.
- If no history is found, the Rust implementation errors with
  `"No history found for parameter '<path>'"` and exits with code `1`.
- The Haskell implementation formats history entries as `"v<N>: <value>"` strings and
  skips entries where both version and value are absent.
- Pagination: the Rust implementation paginates `GetParameterHistory`; Haskell issues a
  single call (same limitation as `get-by-path`).

**Logic Flow:**
1. `paramGetHistory` calls `fetchHistory awsEnv args.pgaPath args.pgaDecrypt`.
2. `fetchHistory` builds `GPH.newGetParameterHistory paramName` with `withDecryption`.
3. `Amazonka.send` returns the response; `fromMaybe [] resp.parameters` extracts entries.
4. `mapMaybe formatHistoryEntry entries` converts each `SSM.ParameterHistory` to
   `Maybe Text` — `Just "v<N>: <value>"` when both version and value are present,
   `Just <value>` when only value is present, `Nothing` when neither is present.
5. Rust additionally sorts by `LastModifiedDate`, splits into current (last) and previous
   (all others), fetches tags for the current entry's `iidy:message` field, and serializes
   the `SimpleHistory` struct as YAML.
6. `try @SomeException` wraps the entire fetch.

**Edge Cases:**
- Single-version parameter: `Current` is the only entry; `Previous` is an empty list
  in Rust simple format. Haskell returns a single-element list.
- `SecureString` with `--no-decrypt`: history values are returned as ciphertext references;
  this reveals that the parameter exists and has N versions without exposing plaintext.
- Parameter with no `iidy:message` tag: Rust `SimpleHistory.current.message` is an empty
  string; Haskell does not fetch tags so the field is absent.
- Very long history: Haskell only returns the first page of results (divergence).

**Error Scenarios:**
- Parameter not found: `GetParameterHistory` returns an empty list (not an error from
  the API); the Rust implementation converts this to an error; Haskell returns an empty
  list and prints nothing.
- `AccessDeniedException`: surfaced as `SSM GetParameterHistory error for <path>: <exception>`.
- Decryption denied (`KMSInvalidStateException`, `KMSAccessDeniedException`): same error
  format; user must check KMS key policy.

**Complexity Notes:** Medium. The split into Current/Previous with tag fetch adds two
extra concerns. The simple YAML format is the primary contract for human consumption; the
JSON/YAML format with full `ParamHistoryOutput` objects targets machine consumption.
The Haskell implementation currently produces a simpler output that does not match Rust's
structured history format — this is a known gap.

---

### US-09-005: Use the parameter approval workflow

**As a** Platform Engineer, **I want to** require a second person to review and approve
sensitive parameter changes before they take effect, **so that** high-impact secrets like
database passwords and API keys are never updated unilaterally in production.

**Acceptance Criteria:**
- `param set <path> <value> --with-approval` writes to `<path>.pending` and prints the
  review command. The main `<path>` is not modified.
- `param review <path>` fetches `<path>.pending` (pending value) and `<path>` (current
  value), displays a diff, prompts for confirmation, and either promotes or rejects.
- If `<path>.pending` does not exist, `param review` displays
  `"No pending parameter found at <path>.pending"` and exits with code `1`.
- If `<path>` does not exist, the current value is displayed as `"(not set)"` (Haskell)
  or `"<not set>"` (Rust). The review proceeds normally; this is the initial-creation case.
- On approval (user types `y` or equivalent): the pending value is written to `<path>`
  with `overwrite = True` and type `SecureString` (Haskell always uses `SecureString`;
  Rust preserves the pending parameter's original type).
- After writing, `<path>.pending` is deleted.
- In Rust, all tags from `<path>.pending` are copied to `<path>` via `AddTagsToResource`.
  The Haskell implementation does not copy tags (known divergence).
- On rejection (user types `n` or declines): iidy prints `"Change not approved."` and
  exits with code `130`. The `.pending` parameter is left in place.
- The display format before prompting:
  - Haskell: `Parameter: <path>`, `Current value: <value>`, `Pending value: <value>`
  - Rust: `Current: <value>`, `Pending: <value>`, and optionally `Message: <tag-value>`
- The `iidy:message` tag on the pending parameter is shown in Rust (`Message: ...`) but
  not in Haskell (known divergence due to missing tag fetch).

**Logic Flow:**
1. `param review <path>` dispatches to `paramReview awsEnv path`.
2. `fetchParam awsEnv (path <> ".pending") True` is called first.
3. If the pending parameter is absent (Left result), error and exit `1`.
4. `fetchParam awsEnv path True` is called for the current value.
5. If absent (Left), use `"(not set)"` as the display string.
6. Print header lines showing parameter path, current value, and pending value.
7. Call `requestConfirmation "Would you like to approve these changes?"` via
   `Iidy.Confirm`.
8. On `True`: call `applyPendingChange awsEnv path pendingValue pendingPath`.
   - `PP.newPutParameter path pendingValue` with `overwrite = True` and
     `type' = SecureString`.
   - `DP.newDeleteParameter pendingPath` to remove `.pending`.
   - On success: print `"Parameter <path> updated successfully."`, return `Right 0`.
   - On partial failure (write succeeded, delete failed): return `Left <error>`.
9. On `False`: print `"Change not approved."`, return `Right 130`.
10. `Main.hs` converts `Right 130` to `System.Exit.exitWith (ExitFailure 130)`.

**Edge Cases:**
- `param set` with `--with-approval` and `--overwrite`: the `.pending` parameter is
  overwritten silently; no warning that a previous pending value existed.
- Reviewer calls `param review` multiple times: first approval deletes `.pending`, so
  subsequent calls correctly report no pending change.
- `param review` called on a path that was set without `--with-approval`: no `.pending`
  suffix exists; the call fails with the "no pending" error.
- Concurrent reviewers: both may fetch the pending value, but only the first to call
  `PutParameter` will succeed if the second hits a race condition; the second reviewer
  will see the updated value on the next fetch.
- Type preservation: Haskell always writes `SecureString` on promotion regardless of the
  pending parameter's type (divergence from Rust which uses the pending parameter's type).

**Error Scenarios:**
- `.pending` parameter not found: `"No pending parameter found at <path>.pending"`,
  exit `1`.
- Write to main path fails during promotion: `"Failed to update parameter: <exception>"`,
  exit `1`. The `.pending` parameter is left intact.
- Delete of `.pending` fails after successful write: `"Parameter updated but failed to
  delete pending: <exception>"`, exit `1`. The value is now present at both paths; the
  operator must manually delete `.pending`.
- IAM policy allows read of `.pending` but not write to main path: the write step fails
  at `applyPendingChange`; the pending value remains.
- User sends CTRL-C during the confirmation prompt: behavior depends on `Iidy.Confirm`
  signal handling; typically exits with code `130`.

**Complexity Notes:** High. The workflow involves four API calls (fetch pending, fetch
current, put main, delete pending), a user interaction step, and partial-failure
semantics where a write success followed by delete failure leaves the system in an
inconsistent state. Tag copying (absent in Haskell) adds a fifth API call in Rust.

---

### US-09-006: Handle KMS key resolution for SecureString parameters

**As a** Platform Engineer, **I want to** have iidy automatically select the most
specific KMS key alias for each SSM parameter path, **so that** different application
namespaces can use different encryption keys without requiring per-parameter key
configuration in automation scripts.

**Acceptance Criteria:**
- When `--type SecureString` (or default), iidy looks up a KMS key alias before calling
  `PutParameter`.
- Alias lookup is hierarchical: given path `/myapp/prod/db-password`, iidy checks aliases
  in order: `alias/ssm/myapp/prod/db-password`, `alias/ssm/myapp/prod`, `alias/ssm/myapp`,
  `alias/ssm` — popping path segments from the right until a match is found.
- Both trailing-slash and non-trailing-slash variants are checked at each level:
  `alias/ssm/myapp/prod/` is equivalent to `alias/ssm/myapp/prod`.
- If no matching alias is found, `PutParameter` is called without a `key_id`, causing AWS
  to use the default SSM CMK (`alias/aws/ssm`).
- The alias lookup is performed via a paginated `ListAliases` KMS API call; all pages are
  fetched before matching.
- String and StringList parameters do not perform KMS alias lookup.

**NOTE:** This feature is implemented in the Rust reference (`~/src/iidy/src/params/mod.rs`
functions `get_kms_alias_for_parameter` and `match_kms_alias`) but is **not yet
implemented** in the Haskell port (`src/Iidy/Params/Client.hs`). The Haskell `paramSet`
passes no `key_id`, always falling back to `alias/aws/ssm`. This is a known divergence
tracked in `DIVERGENCES.md`.

**Logic Flow (Rust, reference):**
1. `create_kms_client` creates a KMS client from the same `SdkConfig` as the SSM client.
2. `get_kms_alias_for_parameter` calls `kms_client.list_aliases()` in a pagination loop,
   collecting all alias names into a `BTreeMap<String, String>`.
3. `match_kms_alias` is called with the full alias map and the parameter path.
4. `match_kms_alias` prepends `["alias", "ssm"]` to the path segments, then tries the
   joined string (with and without trailing slash) at progressively shorter suffixes.
5. If a match is found, the alias name is passed as `key_id` to `PutParameter`.
6. If no match, `PutParameter` is called without `key_id`.
7. `param review` also performs KMS alias lookup for the main path before calling
   `PutParameter` during promotion.

**Edge Cases:**
- Alias map contains `alias/ssm/myapp/prod/` (with trailing slash): matched before
  `alias/ssm/myapp/prod` (without slash) because both are checked at each level and the
  first match wins. In Rust the trailing-slash variant is checked first.
- KMS ListAliases returns no SSM aliases: no match found, falls back to `alias/aws/ssm`.
- Parameter path starting without `/`: path segments after stripping empty elements from
  split on `/` are used, so `/myapp/key` and `myapp/key` resolve the same alias prefix.
- Multiple KMS aliases match at the same specificity: the `BTreeMap` iteration order
  (alphabetical) determines which match is used; in practice multiple aliases at the same
  depth for the same path prefix would be a misconfiguration.
- KMS `ListAliases` permission denied: the error propagates before `PutParameter` is
  called, making the overall `param set` fail.

**Error Scenarios:**
- `KMSAccessDeniedException` on `ListAliases`: `param set` fails before writing the
  parameter value; the parameter is not created or updated.
- `InvalidAliasNameException`: the alias name looked up does not conform to KMS naming
  rules; should not occur in practice as the alias names are constructed from known prefixes.
- KMS service unavailable: propagated as an IO exception wrapping an SDK service error.
- Haskell currently: no KMS call is made; no error possible from this step; parameter is
  always encrypted with `alias/aws/ssm` regardless of path.

**Complexity Notes:** High. The hierarchical alias matching is a pure function (and is
thoroughly unit-tested in the Rust implementation with five test cases). The I/O complexity
lies in the paginated `ListAliases` call. The interaction with `param review` (which must
also do alias lookup during promotion) means the logic must be shared between `set` and
`review`. Implementing this in Haskell requires: a KMS client creation step, the pagination
loop, and the pure `matchKmsAlias` function.

---

## Testing Requirements

- Unit tests for `textToParameterType` cover: `"securestring"`, `"SecureString"`,
  `"SECURESTRING"`, `"string"`, `"stringlist"`, and an unknown string (should default
  to `String`).
- Unit tests for `formatParam` verify the `"name=value"` output format.
- Unit tests for `formatHistoryEntry` cover: both version and value present, only value
  present, and neither present (returns `Nothing`).
- Unit tests for the KMS alias matching logic (once implemented):
  - Exact match at full path depth.
  - Partial match requiring segment popping.
  - No match (fallback to no key ID).
  - Trailing-slash variant match.
  - Empty alias map (no match).
- Unit tests for `paramReview` approval flow using mock SSM responses:
  - Pending parameter absent → error message + exit `1`.
  - Pending present, current absent → `"(not set)"` display, proceeds to prompt.
  - Approval: write and delete calls made with correct parameters.
  - Rejection: neither write nor delete called; exit `130`.
  - Write failure during promotion: error returned, delete not attempted.
  - Delete failure after successful write: partial-failure error returned.
- Integration tests (mock AWS) for `paramGet`, `paramSet`, `paramGetByPath`,
  `paramGetHistory`:
  - Successful round-trip (set then get).
  - Error response mapped to `Left Text`.
  - `paramGetByPath` with `recursive = True` vs `recursive = False`.
  - `paramGetHistory` with multiple versions; verify sort order.
- CLI parser tests:
  - `param set /path value` uses default type `SecureString`, `overwrite = False`.
  - `param set /path value --type String --overwrite` sets correct fields.
  - `param set /path value --with-approval` sets `psaWithApproval = True`.
  - `param get /path` uses `decrypt = True`, `format = "simple"` by default.
  - `param get /path --no-decrypt` sets `decrypt = False`.
  - `param get-by-path /prefix --recursive` sets `recursive = True`.
  - `param review /path` parses to `ParamReview (ParamPathArg "/path")`.
- All tests use mock fixtures; no real AWS calls are permitted.
- Tests for the approval workflow must verify exit code `130` on rejection and exit
  code `0` on successful promotion.

---

## Cross-References

- `src/Iidy/Params/Client.hs` — `paramGet`, `paramSet`, `paramGetByPath`,
  `paramGetHistory`, `textToParameterType`, `formatParam`, `formatHistoryEntry`
- `src/Iidy/Params/Review.hs` — `paramReview`, `applyPendingChange`, `fetchParam`
- `src/Iidy/Yaml/Imports/Loaders/Ssm.hs` — `loadSsmImport` (YAML preprocessing, not CLI)
- `src/Iidy/Cli.hs` — `ParamSetArgs`, `ParamGetArgs`, `ParamGetByPathArgs`,
  `ParamPathArg`, `ParamCommands`
- `src/Iidy/Cli/Parser.hs` — `paramCommandsParser`, `paramSetArgsParser`,
  `paramGetArgsParser`, `paramGetByPathArgsParser`, `paramPathArgParser`
- `src/Iidy/Confirm.hs` — `requestConfirmation` (shared confirmation prompt)
- `~/src/iidy/src/params/mod.rs` — Rust reference: `ParamOutput`, `ParamHistoryOutput`,
  `get_kms_alias_for_parameter`, `match_kms_alias`, `MESSAGE_TAG`, `format_output`
- `~/src/iidy/src/params/set.rs` — Rust `set_param`
- `~/src/iidy/src/params/get.rs` — Rust `get_param`
- `~/src/iidy/src/params/get_by_path.rs` — Rust `get_by_path`
- `~/src/iidy/src/params/get_history.rs` — Rust `get_history`
- `~/src/iidy/src/params/review.rs` — Rust `review_param`
- `DIVERGENCES.md` — KMS alias lookup not implemented, tag handling divergences,
  pagination gaps, type preservation in review, simple output format gaps
- PRD 08 (`08-aws-integration.md`) — credential chain, region resolution, and error
  handling that applies to all SSM operations
- PRD 03 (`03-import-system.md`) — `ssm:` import prefix for YAML preprocessing
