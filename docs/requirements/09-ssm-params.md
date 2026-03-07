# PRD: SSM Parameter Store Operations

## Overview

iidy-hs provides a `param` sub-command group for managing AWS Systems Manager (SSM)
Parameter Store values. The five operations — `set`, `get`, `get-by-path`, `get-history`,
and `review` — cover the full lifecycle of a parameter: creation, retrieval, audit, and
a structured approval workflow for sensitive value changes.

This document specifies requirements derived from the Rust reference implementation under
`~/src/iidy/src/params/` and the behavioral expectations of the `param` command group.

The implementation must achieve byte-for-byte behavioral equivalence with the Rust iidy binary
on all SSM parameter read, write, review, and error display behaviors.

---

## Technical Context

The SSM subsystem is split across two logical concerns:

- **Parameter operations** (`set`, `get`, `get-by-path`, `get-history`): Each operation accepts
  an AWS environment and the relevant command arguments. All operations wrap AWS calls in
  exception handlers and return either an error or a result for uniform error handling.
- **Review workflow** (`review`): Coordinates two SSM fetches (pending + current), displays a
  diff, prompts for confirmation, and on approval writes the pending value to the main path
  and deletes the `.pending` parameter.
- **YAML import loader**: A separate concern used during YAML preprocessing to load SSM parameter
  values as `$import` sources (not part of the `param` CLI group).

The Rust reference implementation lives in `~/src/iidy/src/params/` across six files:
`mod.rs`, `set.rs`, `get.rs`, `get_by_path.rs`, `get_history.rs`, and `review.rs`.

**Output channel:** All `param` sub-commands write directly to stdout. They do not use the
structured output pipeline used by CloudFormation commands. Simple format produces raw text;
JSON and YAML formats produce serialized output.

**KMS key resolution:** For `SecureString` parameters, a hierarchical KMS alias lookup
determines the encryption key before calling `PutParameter`. When no matching alias is found,
the AWS default CMK (`aws/ssm`) is used. See US-09-006 for the full specification.

**Tags:** When `--message` is provided on `param set`, the Rust oracle sets an `iidy:message`
tag via a separate `AddTagsToResource` call after `PutParameter`. In `param review`, all tags
from `.pending` are copied to the promoted parameter.

**Pagination:** The `get-by-path` and `get-history` commands must paginate via `next_token`
to retrieve all results.

**Known divergences** (see `DIVERGENCES.md`):

- KMS alias lookup is not yet implemented; parameters always use `alias/aws/ssm`.
- `--message` sets the description field, not the `iidy:message` tag.
- Tag copying in `param review` is not yet implemented.

**Previously divergent, now implemented:**

- Pagination in `get-by-path` and `get-history` uses `Amazonka.paginate` with conduit.
- Structured JSON/YAML output for `param get` non-simple formats is implemented via
  `ParamOutput` and `ParamHistoryOutput` types with `ToJSON` instances.
- `param get-by-path` returns `ByPathEmpty` for empty results (exit code 1 path).

**Output data types** (used for `--format json` and `--format yaml`):

```haskell
data ParamOutput = ParamOutput
    { poName             :: Maybe Text
    , poType             :: Maybe Text
    , poValue            :: Maybe Text
    , poVersion          :: Maybe Integer
    , poLastModifiedDate :: Maybe Text
    , poArn              :: Maybe Text
    , poDataType         :: Maybe Text
    , poTags             :: Maybe (Map Text Text)  -- included for non-simple formats
    }

data ParamHistoryOutput = ParamHistoryOutput
    { phoName             :: Maybe Text
    , phoType             :: Maybe Text
    , phoKeyId            :: Maybe Text
    , phoLastModifiedDate :: Maybe Text
    , phoLastModifiedUser :: Maybe Text
    , phoDescription      :: Maybe Text
    , phoValue            :: Maybe Text
    , phoVersion          :: Maybe Integer
    , phoDataType         :: Maybe Text
    , phoTags             :: Maybe (Map Text Text)
    }

data SimpleHistory = SimpleHistory
    { shCurrent  :: SimpleHistoryCurrent   -- current entry with message from iidy:message tag
    , shPrevious :: [SimpleHistoryPrevious] -- all older entries
    }

data FullHistory = FullHistory
    { fhCurrent  :: ParamHistoryOutput     -- current entry with tags
    , fhPrevious :: [ParamHistoryOutput]   -- previous entries without tags
    }
```

JSON field names use PascalCase (`Name`, `Type`, `Value`, `Version`,
`LastModifiedDate`, `ARN`, `DataType`, `Tags`) matching AWS SDK conventions.

**CLI arguments:**

- `param set`: path (positional), value (positional), `--message`, `--overwrite`, `--with-approval`, `--type` (`SecureString` | `String` | `StringList`; default `SecureString`)
- `param get`: path (positional), `--no-decrypt`, `--format` (`simple` | `json` | `yaml`; default `simple`)
- `param get-by-path`: path (positional), `--no-decrypt`, `--format`, `--recursive`
- `param get-history`: path (positional), `--no-decrypt`, `--format`
- `param review`: path (positional)

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
- The parameter type string is case-insensitive: `"securestring"`,
  `"SecureString"`, and `"SECURESTRING"` all map to `SecureString`.
- Unknown type strings fall through to `String`.

**Logic Flow:**

```
paramSet awsEnv args:
  effectivePath = if args.withApproval
                  then args.path <> ".pending"
                  else args.path
  paramType = paramTypeToSsm args.type
    -- ParamString     -> ParameterType_String
    -- ParamSecureString -> ParameterType_SecureString
    -- ParamStringList -> ParameterType_StringList
  req = PutParameter
    { name        = effectivePath
    , value       = args.value
    , overwrite   = args.overwrite
    , type'       = paramType
    , description = args.message   -- NOTE: sets description, not iidy:message tag
    }
  result <- try (send awsEnv req)
  case result of
    Left ex  -> Left ("SSM PutParameter error for " <> path <> ": " <> show ex)
    Right _  -> Right ()
  -- If --with-approval, caller prints approval reminder to stdout
```

**NOTE:** The Rust oracle sets an `iidy:message` tag via `AddTagsToResource` after
`PutParameter`. The current implementation sets the SSM `description` field instead.
This is a known divergence.

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
- `InvalidKeyId`: KMS key alias not found (in Rust; currently no key ID is passed so
  the `aws/ssm` default is always used — no error in this implementation).
- AWS credentials missing or expired: surfaced by the top-level error handler before the
  SSM call is attempted.
- SSM service unavailable: the exception is caught; error text is printed; process exits
  with code `1`.

**Complexity Notes:** Low. The operation is a single `PutParameter` call. The KMS alias
lookup (present in Rust) is not yet implemented, reducing complexity at the cost of a
known divergence. The `--with-approval` path rename is purely local string manipulation.

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
  separate `ListTagsForResource` call.
- Exit code is `0` on success, `1` on AWS error (parameter not found, no permission).

**Logic Flow:**

```
paramGet awsEnv args:
  case args.format of
    Simple ->
      result <- fetchParam awsEnv args.path args.decrypt
        -- GetParameter { name, withDecryption } -> extract parameter_value
      case result of
        Left ex  -> Left (errPrefix <> show ex)
        Right val -> Right val     -- bare value string, caller prints with newline

    Json | Yaml ->
      param  <- fetchParameter awsEnv args.path args.decrypt
        -- GetParameter -> extract full Parameter object
      tags   <- listParamTags awsEnv args.path
        -- ListTagsForResource Parameter args.path -> Map Text Text
      output  = withParamTags tags (paramOutputFromParameter param)
      case format of
        Json -> formatAsJson output   -- pretty-printed JSON, 2-space indent
        Yaml -> formatAsYaml output   -- "---\n" prefixed YAML
```

Tag fetching via `ListTagsForResource` adds one extra API call per parameter for
non-simple formats.

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
implementation. Structured JSON/YAML output for non-simple formats is implemented
via `ParamOutput` with `ToJSON` instances (see Technical Context).

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
- `--format simple` (default) prints a YAML map of `{path: value}`, sorted by path.
- `--format json` and `--format yaml` print a map of `{path: ParamOutput}` objects with
  tag fields included.
- If no parameters exist under the path, print `"No parameters found"` and exit with code `1`.
- Results are sorted alphabetically by parameter name.
- Pagination: follow `next_token` to retrieve all results across API pages.

**Logic Flow:**

```
paramGetByPath awsEnv args:
  params <- fetchByPathRaw awsEnv args
    -- GetParametersByPath { path, recursive, withDecryption }
    -- Paginated via Amazonka.paginate + conduit:
    --   pages <- runConduit $ paginate awsEnv req .| CL.consume
    --   concat all page.parameters
  if null params then
    return ByPathEmpty       -- caller prints "No parameters found", exit 1

  sorted = sortBy (comparing parameter_name) params

  case args.format of
    Simple ->
      m = Map.fromList [(p.name, p.value) | p <- sorted]
      return ByPathOutput (formatAsYaml m)

    Json | Yaml ->
      -- Sequential tag fetch: O(n) ListTagsForResource calls
      m <- buildTaggedMap awsEnv sorted
        -- for each param: listParamTags -> Map.insert name (withParamTags tags po) acc
      return ByPathOutput (formatWith format m)
```

**Edge Cases:**
- Path prefix with no trailing slash: SSM `GetParametersByPath` requires the path to
  start with `/`; behavior for paths not starting with `/` is SDK-defined.
- Recursive with a deep tree: all levels are included via pagination; no additional
  calls are made per level.
- Mix of `SecureString` and `String` parameters under one prefix: both are returned in
  the response; decryption applies to all.

**Error Scenarios:**
- Path prefix does not exist: API returns an empty `parameters` list, not an error.
- Path without `/` prefix: SSM SDK may return `InvalidFilterValue`; surfaced as
  `SSM GetParametersByPath error for <path>: <exception>`.
- IAM permissions allow `GetParameter` but not `GetParametersByPath`: returns
  `AccessDeniedException`; displayed as error, exits with code `1`.

**Complexity Notes:** Medium. The simple format YAML map (sorted by path) is the primary
output contract. The structured JSON/YAML output with tag fetching adds one additional
API call per parameter.

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
  includes tags. `Previous` entries do not include tags.
- If no history is found, error with
  `"No history found for parameter '<path>'"` and exit with code `1`.
- History entries are formatted as `"v<N>: <value>"` strings and entries where both
  version and value are absent are skipped.
- Pagination: follow `next_token` to retrieve all history pages.

**Logic Flow:**

```
paramGetHistory awsEnv args:
  entries <- fetchHistoryRaw awsEnv args.path args.decrypt
    -- GetParameterHistory { name, withDecryption }
    -- Paginated via Amazonka.paginate + conduit:
    --   pages <- runConduit $ paginate awsEnv req .| CL.consume
    --   concat all page.parameters
  case NonEmpty.nonEmpty entries of
    Nothing -> Left "No history found for parameter '<path>'"
    Just ne ->
      sorted  = NE.sortBy (comparing lastModifiedDate) ne
      current  = NE.last sorted
      previous = NE.init sorted
      tagMap  <- listParamTags awsEnv args.path

      case args.format of
        Simple ->
          msg = Map.lookup "iidy:message" tagMap |> fromMaybe ""
          SimpleHistory
            { current  = { value, lastModifiedDate, lastModifiedUser, message = msg }
            , previous = [{ value, lastModifiedDate, lastModifiedUser } | p <- previous]
            }
          formatAsYaml result

        Json | Yaml ->
          FullHistory
            { current  = withHistoryTags tagMap (paramHistoryOutputFromHistory current)
            , previous = map paramHistoryOutputFromHistory previous
            }
          formatWith format result
```

The `formatHistoryEntry` helper formats individual entries as `"v<N>: <value>"`:
- Both version and value present: `"v3: some-value"`
- Value only (no version): `"some-value"`
- Neither present: entry is skipped (`Nothing`)

**Edge Cases:**
- Single-version parameter: `Current` is the only entry; `Previous` is an empty list.
- `SecureString` with `--no-decrypt`: history values are returned as ciphertext references;
  this reveals that the parameter exists and has N versions without exposing plaintext.
- Parameter with no `iidy:message` tag: `SimpleHistory.current.message` is an empty string.

**Error Scenarios:**
- Parameter not found: `GetParameterHistory` returns an empty list (not an error from
  the API); this is converted to an error: `"No history found for parameter '<path>'"`,
  exit 1.
- `AccessDeniedException`: surfaced as `SSM GetParameterHistory error for <path>: <exception>`.
- Decryption denied (`KMSInvalidStateException`, `KMSAccessDeniedException`): same error
  format; user must check KMS key policy.

**Complexity Notes:** Medium. The split into Current/Previous with tag fetch adds two
extra concerns. The simple YAML format is the primary contract for human consumption; the
JSON/YAML format with full `ParamHistoryOutput` objects targets machine consumption.

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
- If `<path>` does not exist, the current value is displayed as `"<not set>"`. The review
  proceeds normally; this is the initial-creation case.
- On approval (user types `y` or equivalent): the pending value is written to `<path>`
  with `overwrite = True`, preserving the pending parameter's original type.
- After writing, `<path>.pending` is deleted.
- After writing, all tags from `<path>.pending` are copied to `<path>` via
  `AddTagsToResource`.
- On rejection (user types `n` or declines): iidy prints `"Change not approved."` and
  exits with code `130`. The `.pending` parameter is left in place.
- The display format before prompting: `Current: <value>`, `Pending: <value>`, and
  optionally `Message: <tag-value>` if the `iidy:message` tag is set on the pending
  parameter.

**Logic Flow:**

```
paramReview awsEnv path:
  pendingPath = path <> ".pending"

  -- 1. Fetch pending parameter (full object to preserve type)
  pendingResult <- fetchParamFull awsEnv pendingPath withDecryption=True
  case pendingResult of
    Left _  -> Left ("No pending parameter found at " <> pendingPath)
    Right pendingParam ->
      pendingValue = pendingParam.value
      paramType    = pendingParam.type   -- preserves original type (not hardcoded SecureString)

      -- 2. Fetch current value
      currentResult <- fetchParam awsEnv path withDecryption=True
      currentValue   = fromRight "(not set)" currentResult

      -- 3. Display
      print ""
      print "Parameter: " <> path
      print "Current value: " <> currentValue
      print "Pending value: " <> pendingValue
      print ""

      -- 4. Prompt
      result <- requestConfirmation "Would you like to approve these changes?"
      case result of
        Confirmed ->
          -- 5. Write pending value preserving original type
          putReq = PutParameter { name=path, value=pendingValue, overwrite=True, type'=paramType }
          putResult <- try (send awsEnv putReq)
          case putResult of
            Left ex  -> Left ("Failed to update parameter: " <> show ex)
            Right _  ->
              -- Delete pending
              delReq = DeleteParameter pendingPath
              delResult <- try (send awsEnv delReq)
              case delResult of
                Left ex  -> Left ("Parameter updated but failed to delete pending: " <> show ex)
                Right _  ->
                  print "Parameter " <> path <> " updated successfully."
                  Right 0

        Declined ->
          print "Change not approved."
          Right 130
```

**NOTE:** The write preserves the pending parameter's original type (could be
`String`, `SecureString`, or `StringList`) rather than hardcoding `SecureString`.
Tag copying from `.pending` to the main parameter is not yet implemented.

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
- Type preservation: promotion preserves the pending parameter's original type.

**Error Scenarios:**
- `.pending` parameter not found: `"No pending parameter found at <path>.pending"`,
  exit `1`.
- Write to main path fails during promotion: `"Failed to update parameter: <exception>"`,
  exit `1`. The `.pending` parameter is left intact.
- Delete of `.pending` fails after successful write: `"Parameter updated but failed to
  delete pending: <exception>"`, exit `1`. The value is now present at both paths; the
  operator must manually delete `.pending`.
- IAM policy allows read of `.pending` but not write to main path: the write step fails
  and the pending value remains.
- User sends CTRL-C during the confirmation prompt: typically exits with code `130`.

**Complexity Notes:** High. The workflow involves four API calls (fetch pending, fetch
current, put main, delete pending), a user interaction step, and partial-failure
semantics where a write success followed by delete failure leaves the system in an
inconsistent state. Tag copying (not yet implemented) adds a fifth API call in Rust.

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

**NOTE:** This feature is a known divergence (not yet implemented); see Technical Context.

**Logic Flow:**
1. Create a KMS client from the same credential configuration as the SSM client.
2. Call `ListAliases` in a pagination loop, collecting all alias names.
3. Call the alias matching function with the full alias map and the parameter path.
4. The matcher prepends `["alias", "ssm"]` to the path segments, then tries the
   joined string (with and without trailing slash) at progressively shorter suffixes.
5. If a match is found, the alias name is passed as `key_id` to `PutParameter`.
6. If no match, `PutParameter` is called without `key_id`.
7. `param review` also performs KMS alias lookup for the main path before calling
   `PutParameter` during promotion.

**NOTE:** The KMS alias lookup logic is a pure function suitable for unit testing
independently of AWS calls.

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
**Complexity Notes:** High. The hierarchical alias matching is a pure function. The I/O
complexity lies in the paginated `ListAliases` call. The interaction with `param review`
(which must also do alias lookup during promotion) means the logic must be shared between
`set` and `review`.

---

## Testing Requirements

- Unit tests for parameter type normalization: `"securestring"`, `"SecureString"`,
  `"SECURESTRING"`, `"string"`, `"stringlist"`, and an unknown string (should default
  to `String`).
- Unit tests for the `name=value` output format for single parameters.
- Unit tests for history entry formatting: both version and value present, only value
  present, and neither present (should be skipped).
- Unit tests for the KMS alias matching logic (once implemented):
  - Exact match at full path depth.
  - Partial match requiring segment popping.
  - No match (fallback to no key ID).
  - Trailing-slash variant match.
  - Empty alias map (no match).
- Unit tests for the review approval flow using mock SSM responses:
  - Pending parameter absent → error message + exit `1`.
  - Pending present, current absent → `"(not set)"` display, proceeds to prompt.
  - Approval: write and delete calls made with correct parameters.
  - Rejection: neither write nor delete called; exit `130`.
  - Write failure during promotion: error returned, delete not attempted.
  - Delete failure after successful write: partial-failure error returned.
- Integration tests (mock AWS) for `param get`, `param set`, `param get-by-path`,
  `param get-history`:
  - Successful round-trip (set then get).
  - Error response mapped to an error string.
  - `get-by-path` with `--recursive` vs without.
  - `get-history` with multiple versions; verify sort order.
- CLI parser tests:
  - `param set /path value` uses default type `SecureString`, `overwrite = False`.
  - `param set /path value --type String --overwrite` sets correct fields.
  - `param set /path value --with-approval` enables the approval path.
  - `param get /path` uses `decrypt = True`, `format = "simple"` by default.
  - `param get /path --no-decrypt` sets `decrypt = False`.
  - `param get-by-path /prefix --recursive` sets `recursive = True`.
  - `param review /path` parses to the review command with path `"/path"`.
- All tests use mock fixtures; no real AWS calls are permitted.
- Tests for the approval workflow must verify exit code `130` on rejection and exit
  code `0` on successful promotion.

---

## Cross-References

- `DIVERGENCES.md` — known behavioral differences (KMS alias lookup, tag handling,
  pagination, type preservation in review, structured output formats)
- PRD `08-aws-integration.md` — credential chain, region resolution, and error
  handling that applies to all SSM operations
- PRD `03-import-system.md` — `ssm:` import prefix for YAML preprocessing
- Rust oracle: `~/src/iidy/src/params/` — read-only reference for behavioral verification
