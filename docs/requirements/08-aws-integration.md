# PRD: AWS Integration

## Overview

iidy-hs integrates with AWS via the amazonka library to authenticate, authorize, and execute
CloudFormation operations. The integration covers credential discovery, region resolution,
IAM role assumption, NTP time synchronization for write operations, STS identity retrieval
for metadata, and graceful error handling across all credential failure modes.

This document captures retroactive requirements derived from the implemented behavior in
`src/Iidy/Aws/Config.hs`, `src/Iidy/Aws/CredentialSource.hs`, `src/Iidy/Aws/Sts.hs`,
`src/Iidy/Aws/Time.hs`, and `src/Iidy/Types/AwsSettings.hs`.

The implementation achieves byte-for-byte behavioral equivalence with the Rust iidy binary
on all credential chain, region resolution, assume-role, and error display behaviors tested
during live AWS verification in Phase 14.

## Implementation Context

The AWS configuration subsystem consists of:

- `Iidy.Aws.Config` — credential discovery, region resolution, env setup (`createAwsEnv`)
- `Iidy.Aws.CredentialSource` — `CredentialSource` ADT, `CredentialSourceStack`, display
- `Iidy.Types.AwsSettings` — `AwsSettings`, `AwsOpts`, `mergeAwsSettings`, env-map parsing
- `Iidy.Aws.Sts` — `getCallerIdentity` with graceful fallback
- `Iidy.Aws.Time` — `ReliableTimeProvider` (NTP) and `SystemTimeProvider`

The monad stack is plain IO with an `Amazonka.Env` passed explicitly via `CfnContext`. No
transformer stack wraps credential state. Settings flow from CLI parsing → `AwsOpts` →
`mergeAwsSettings` with stack-args `AwsSettings` → final `AwsSettings` → `createAwsEnv`.

---

## User Stories

### US-08-001: Authenticate via environment variables

**As a** CI Pipeline, **I want to** supply AWS credentials through environment variables,
**so that** I can authenticate without persistent credential files or profile configuration
on ephemeral build agents.

**Acceptance Criteria:**
- When `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set, iidy uses them as the
  active credential source without requiring any profile or config file.
- When `AWS_SESSION_TOKEN` is also set, iidy recognizes the credentials as temporary
  (STS-issued) and displays them accordingly.
- When only `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set (no session token),
  iidy treats them as static long-lived credentials.
- Environment variable credentials take priority over all other sources (profiles, instance
  metadata, container credentials).
- The credential display name in command metadata reflects the source:
  - Static: `environment variables (AWS_ACCESS_KEY_ID)`
  - Temporary: `environment variables (AWS_ACCESS_KEY_ID + AWS_SESSION_TOKEN)`

**Logic Flow:**
1. `detectCredentialSources` checks `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` via
   `hasEnv` (non-empty value required).
2. If both are present and `AWS_SESSION_TOKEN` is also set → `EnvironmentVariablesTemporary`.
3. If both are present but no session token → `EnvironmentVariablesStatic`.
4. The detected source is placed first in the `CredentialSourceStack`.
5. `createAwsEnv` calls `Amazonka.newEnv Amazonka.discover`; amazonka's own discovery chain
   picks up the same env vars and uses them for actual API calls.

**Edge Cases:**
- `AWS_ACCESS_KEY_ID` set but `AWS_SECRET_ACCESS_KEY` absent: treated as no env var
  credentials; falls through to next source in chain.
- Empty string values for credential variables are treated as absent (`hasEnv` checks
  `not . null`).
- `AWS_SESSION_TOKEN` present without the key pair: no effect on credential source type.

**Error Scenarios:**
- Expired session tokens are detected by AWS service responses after the request is made;
  iidy surfaces the amazonka `ServiceError` with a formatted message.
- Malformed key values are rejected by AWS at request time, not at configuration time.

**Complexity Notes:** Low. Detection is a pure environment check; actual credential loading
is delegated entirely to `Amazonka.discover`.

---

### US-08-002: Use named AWS profiles

**As a** Developer, **I want to** select a named AWS profile for iidy commands, **so that**
I can switch between accounts and roles defined in my `~/.aws/credentials` and
`~/.aws/config` files without changing environment variables.

**Acceptance Criteria:**
- `--profile <name>` sets the named profile as the active credential source.
- `--profile=no-profile` suppresses any profile specified in the stack-args file and forces
  iidy to use only environment variable credentials.
- When no `--profile` flag is given, a `Profile` field in the stack-args file is used.
- When neither CLI nor stack-args specifies a profile, `AWS_PROFILE` env var is used.
- When none of the above is set, the `default` profile is used.
- The CLI `--profile` flag always wins over the stack-args `Profile` field.
- Profile source is tracked and reported in credential display:
  - CLI flag: `profile 'myprofile' (CLI flag)`
  - Stack-args: `profile 'myprofile' (stack-args)`
  - Env var: `profile 'myprofile' (AWS_PROFILE)`
  - Default: `profile 'default' (default)`

**Logic Flow:**
1. `mergeAwsSettings` applies CLI `AwsOpts` over stack-args `AwsSettings`; CLI profile
   wins via `(<|>)`.
2. If `--profile=no-profile`, `awsProfile` is set to `Nothing`, suppressing stack-args.
3. `createAwsEnv` calls `setEnv "AWS_PROFILE" profile` before `Amazonka.discover`, ensuring
   the profile is active for amazonka's full discovery chain (credentials + config).
4. `detectCredentialSources` separately reads `AWS_PROFILE` and the detection context to
   record `ProfileInfo { piName, piSource }` for display.
5. `determineProfile` applies priority: CLI flag > stack-args > `AWS_PROFILE` > default.

**Edge Cases:**
- Profile names with spaces or special characters are passed verbatim to `setEnv`.
- If the named profile does not exist in `~/.aws/credentials`, amazonka's discovery fails
  at the point of the first AWS API call with a credential error.
- Setting `AWS_PROFILE` externally before running iidy is equivalent to providing no `--profile`
  flag — the env var is used as the third-priority fallback.
- `--profile=no-profile` is the only way to explicitly disable a profile set in stack-args;
  there is no `--no-profile` boolean flag.

**Error Scenarios:**
- Unknown profile name: no error at startup; fails at first AWS call with amazonka credential
  error surfaced as a formatted message.
- Profile file permission errors: propagated by amazonka at discovery time.

**Complexity Notes:** Medium. The `setEnv` side-effect must occur before `Amazonka.discover`
is called. The `no-profile` sentinel value requires convention-based handling in `mergeAwsSettings`.

---

### US-08-003: Assume an IAM role for operations

**As a** Platform Engineer, **I want to** configure iidy to assume an IAM role before
executing CloudFormation operations, **so that** I can enforce least-privilege access and
use cross-account role chains without managing separate credential sets.

**Acceptance Criteria:**
- `--assume-role-arn <ARN>` causes iidy to call STS `AssumeRole` using the base credentials
  and use the resulting temporary credentials for all AWS operations.
- `--assume-role-arn=no-role` suppresses any `AssumeRoleARN` field in the stack-args file.
- A `AssumeRoleARN` field in stack-args is used when no `--assume-role-arn` flag is given.
- The STS session name is always `"iidy"`.
- Assumed-role credentials are automatically refreshed in the background via amazonka's
  `STS.fromAssumedRole` mechanism; no manual refresh is required.
- The credential display shows the role ARN and the base source:
  `assume-role arn:aws:iam::123456789:role/MyRole via profile 'default' (default)`
- The CLI `--assume-role-arn` flag wins over the stack-args `AssumeRoleARN` field.

**Logic Flow:**
1. `mergeAwsSettings` merges CLI `AwsOpts.optAssumeRoleArn` over stack-args `awsAssumeRoleArn`
   via `(<|>)`.
2. If `--assume-role-arn=no-role`, the merged value is `Nothing`.
3. `createAwsEnv` builds the base env with `Amazonka.discover` and region applied first.
4. If `awsAssumeRoleArn` is `Just arn`, calls `STS.fromAssumedRole roleArn "iidy" env'`
   which returns a new `Amazonka.Env` backed by auto-refreshing STS credentials.
5. `detectCredentialSources` wraps the highest-priority base source in
   `AssumeRoleCredential (AssumeRoleInfo baseSource arn AssumeRoleCliFlag)`.
6. `sourceDisplayName` formats the wrapped source recursively.

**Edge Cases:**
- Role ARN with a condition requiring MFA: STS call fails; the error is surfaced at
  command startup before any CloudFormation operation is attempted.
- Chained role assumptions (role A assumes role B): the `--assume-role-arn` flag only
  performs one level of assumption; chained roles require profile-based configuration.
- If assume-role is specified in stack-args but `--assume-role-arn=no-role` is passed,
  the stack-args role is completely suppressed.
- `no-role` sentinel: only the literal string `"no-role"` suppresses the stack-args role.

**Error Scenarios:**
- Invalid ARN format: STS returns an error at call time; formatted and displayed to user.
- Insufficient permissions for AssumeRole: STS returns AccessDenied; displayed as a
  formatted error with the ARN included.
- STS service unavailable: propagated as an amazonka service error.

**Complexity Notes:** Medium-high. The base env must be fully configured (region, profile)
before assume-role is applied. The `STS.fromAssumedRole` call makes a real network request
at startup for write operations.

---

### US-08-004: Resolve AWS region from multiple sources

**As a** Developer, **I want to** specify the AWS region through whichever configuration
source is most convenient for my workflow, **so that** I can run iidy without always
providing a `--region` flag while still having explicit control when needed.

**Acceptance Criteria:**
- Region is resolved in strict priority order: `--region` CLI flag > stack-args `Region`
  field > `AWS_REGION` env var > `AWS_DEFAULT_REGION` env var.
- If no region is found in any source, iidy exits with an error listing all configuration
  sources, not silently defaulting to `us-east-1`.
- Region values from stack-args support environment maps (see US-08-008).
- The resolved region is applied to the `Amazonka.Env` before any API call.

**Logic Flow:**
1. `mergeAwsSettings` merges CLI region over stack-args region via `(<|>)`.
2. `resolveRegion (awsRegion settings)` is called with the merged `Maybe Text`.
3. If `Just r`: converts directly via `textToRegion` (wraps `Amazonka.Region'`).
4. If `Nothing`: checks `AWS_REGION` env var.
5. If still `Nothing`: checks `AWS_DEFAULT_REGION` env var.
6. If still `Nothing`: calls `fail` with a multi-line error message listing all sources.
7. The resolved region replaces `Amazonka.Env.region` via record update.

**Edge Cases:**
- Malformed region strings (e.g., `"us-east-"`) are passed to `Amazonka.Region'` without
  validation; AWS will reject them at the first API call.
- `AWS_REGION` and `AWS_DEFAULT_REGION` both set: `AWS_REGION` wins.
- Stack-args `Region` set to an environment map with no matching key: resolves to `Nothing`,
  falls through to env vars.
- `--region` provided alongside stack-args `Region`: CLI always wins.

**Error Scenarios:**
- No region configured anywhere:
  ```
  No AWS region configured. Please specify a region via:
    - CLI flag: --region us-east-1
    - Stack args: Region: us-east-1
    - Environment variable: AWS_REGION or AWS_DEFAULT_REGION
    - AWS config file: ~/.aws/config
  ```
- The error message is emitted by `fail` in IO, resulting in a runtime exception caught
  and displayed by the top-level AWS error handler in `Main.hs`.

**Complexity Notes:** Low. Pure priority chain in `resolveRegion`; no network calls.

---

### US-08-005: Use NTP time synchronization for write operations

**As a** CI Pipeline, **I want to** iidy to use NTP-synchronized time for CloudFormation
write operations, **so that** timestamp-sensitive operations like changeset creation
succeed even when the system clock is skewed relative to AWS service time.

**Acceptance Criteria:**
- Write operations (create-stack, update-stack, create-changeset, exec-changeset,
  delete-stack, create-or-update) use `ReliableTimeProvider`, which queries NTP first.
- Read operations (describe-stack, watch-stack, list-stacks, etc.) use `SystemTimeProvider`
  (plain `getCurrentTime`), making no network calls.
- NTP queries use SNTP protocol against `pool.ntp.org:123` with a 2-second timeout and
  up to 2 retries.
- If NTP fails (timeout, network error, parse error), iidy falls back to system time and
  continues without error.
- NTP epoch (seconds since 1900-01-01) is correctly converted to Unix epoch
  (seconds since 1970-01-01) using the 70-year offset of 2,208,988,800 seconds.
- No NTP call is made for read-only commands.

**Logic Flow:**
1. Command dispatch in `Main.hs` selects `ReliableTimeProvider` or `SystemTimeProvider`
   based on whether the command is a write operation.
2. `ReliableTimeProvider.getTime` attempts SNTP query via UDP socket.
3. On success: converts NTP timestamp to `UTCTime` and returns it.
4. On failure: catches all IO exceptions, logs a warning, returns `getCurrentTime`.
5. The time provider is threaded through `CfnContext` and used when timestamps are needed.

**Edge Cases:**
- NTP server unreachable (firewall, air-gapped environment): silent fallback to system
  time; no user-visible error.
- NTP response with implausible timestamp (more than 1 year from system time): treated
  as a parse failure, falls back to system time.
- Multiple write operations in the same command invocation: NTP is queried once at
  startup and the result is reused.

**Error Scenarios:**
- NTP query timeout after retries: logged as a warning to stderr (not visible in normal
  output), system time used as fallback.
- UDP socket creation failure (restricted environments): caught, system time used.

**Complexity Notes:** Medium. Requires custom SNTP client (~100 LOC) due to no suitable
Haskell library. The NTP-to-Unix epoch conversion must handle the 1900/1970 difference
correctly to avoid timestamp errors.

---

### US-08-006: View credential provenance in command metadata

**As a** Developer, **I want to** see which credential source and AWS account iidy is
using when I run a command, **so that** I can confirm I am operating against the intended
account and role before changes are applied.

**Acceptance Criteria:**
- Command metadata displayed before CloudFormation operations includes:
  - AWS account ID (from STS `GetCallerIdentity`)
  - IAM ARN of the calling principal
  - Active credential source description
  - AWS region in use
- The credential source description accurately reflects the full chain including
  assume-role wrappers and the base source that was overridden.
- If STS `GetCallerIdentity` fails (no permissions, network error), metadata displays
  `"unknown"` for both account ID and ARN rather than failing the command.
- When multiple credential sources are detected (e.g., env vars present but profile
  used via assume-role), the active source and overridden sources are both listed.

**Logic Flow:**
1. `createAwsEnv` returns `(Amazonka.Env, CredentialSourceStack)`.
2. `CredentialSourceStack` is a list where index 0 is the active source.
3. `credentialDisplayName` formats the stack:
   - Single source: just the source name.
   - Multiple sources: `"<active> (overriding <s1> and <s2>)"`.
4. `getCallerIdentity` calls STS and returns `(accountId, arnText)` or
   `("unknown", "unknown")` on any failure.
5. `constructCommandMetadata` assembles `CommandMetadata` with both pieces.
6. The renderer emits the metadata block before the main operation output.

**Edge Cases:**
- Assume-role wrapping an env var source: display reads
  `"assume-role arn:...:role/X via environment variables (AWS_ACCESS_KEY_ID)"`.
- Profile source with source `ProfileDefault` displays `"profile 'default' (default)"`.
- `getCallerIdentity` called before assume-role is applied: would reflect base identity.
  The implementation calls it after `createAwsEnv` returns the final env, so it reflects
  the assumed role identity.

**Error Scenarios:**
- `sts:GetCallerIdentity` denied by IAM policy: caught, `("unknown", "unknown")` returned,
  command proceeds normally.
- STS endpoint unreachable: same fallback behavior as permission denial.

**Complexity Notes:** Low-medium. The credential stack display is purely textual formatting
over a simple ADT. STS call is best-effort with explicit fallback.

---

### US-08-007: Handle authentication failures gracefully

**As a** Developer, **I want to** receive clear, actionable error messages when AWS
authentication fails, **so that** I can quickly identify and resolve credential or
configuration problems without reading raw SDK exception output.

**Acceptance Criteria:**
- Missing region error includes a formatted list of all configuration sources the user
  can use to provide a region.
- AWS `ServiceError` responses are extracted from the amazonka exception type and
  displayed with the HTTP status code and error message, not as a raw Haskell exception.
- Credential errors (missing, expired, insufficient permissions) are displayed with
  context about which operation failed.
- Errors during assume-role (STS `AccessDenied`, invalid ARN) are shown before any
  CloudFormation operation begins.
- STS `GetCallerIdentity` failures do not block command execution; they degrade
  gracefully to unknown identity display.
- All AWS errors are written to stderr; successful output goes to stdout (or the
  configured output destination).

**Logic Flow:**
1. Top-level error handler in `Main.hs` catches `SomeException`.
2. `Amazonka.serviceError` pattern matches amazonka service errors.
3. For service errors: extracts HTTP status and error message text, formats them.
4. For IO exceptions (including the region `fail`): formats the message string directly.
5. Output goes to stderr via `hPutStrLn stderr`.
6. Process exits with a non-zero exit code.

**Edge Cases:**
- Expired temporary credentials detected mid-operation (after the first successful call):
  the next AWS call fails; the error is surfaced like any other service error.
- Credential error during STS assume-role: the `STS.fromAssumedRole` call in
  `createAwsEnv` throws before any CloudFormation operation starts.
- Multiple overlapping errors (e.g., region missing AND no credentials): only the first
  error encountered in the setup sequence is reported.

**Error Scenarios:**
- `NoCredentialSources`: amazonka discovery found no credentials anywhere.
- `ExpiredTokenException`: session token has expired; user must refresh.
- `AccessDeniedException`: IAM policy denies the requested operation.
- Network timeout connecting to AWS endpoint: propagated as an IO exception.

**Complexity Notes:** Medium. Requires pattern-matching on amazonka's exception hierarchy
to extract service error details. The region error uses `fail` in IO which becomes a
`SomeException`; the message format must be preserved through exception propagation.

---

### US-08-008: Use environment-mapped AWS settings

**As a** Platform Engineer, **I want to** define environment-specific AWS settings in a
single stack-args file, **so that** the same deployment file can be used across dev, staging,
and production environments without modification.

**Acceptance Criteria:**
- The `Profile`, `Region`, and `AssumeRoleARN` fields in stack-args accept both a plain
  string and an environment map of the form `{dev: value1, prod: value2}`.
- When an environment map is provided, the value for the active environment key is used.
- When the active environment key is not present in the map, the field resolves to `Nothing`
  (falls through to lower-priority sources).
- Plain string values behave identically to an environment map with a single catch-all entry.
- CLI flags always override environment-mapped values from stack-args.
- An environment map for `Region` follows the same priority rules as a plain string Region.

**Logic Flow:**
1. Stack-args YAML is parsed with `parseAwsSettings`.
2. For each of `Profile`, `Region`, `AssumeRoleARN`: the field value is parsed as either
   a `Text` (plain string) or an `Object` (environment map via `HashMap Text Text`).
3. If an environment map, the active environment name is looked up in the map.
4. The resolved `Maybe Text` is stored in `AwsSettings`.
5. `mergeAwsSettings` applies `(<|>)` so CLI opts win over resolved stack-args values.

**Edge Cases:**
- Environment map with uppercase keys vs. lowercase active environment name: key
  lookup is case-sensitive; mismatches result in `Nothing` (no match).
- Nested environment maps are not supported; values must be plain strings.
- Stack-args `Profile: no-profile` (plain string): treated as the profile named
  `"no-profile"`, not as suppression; only the CLI `--profile=no-profile` flag suppresses.
- Environment map with a key matching `"no-profile"` is valid and would set the profile
  to the string `"no-profile"`.

**Error Scenarios:**
- YAML parse error in the environment map (non-string value): reported as a stack-args
  validation error before any AWS configuration is attempted.
- All environment map keys are absent for the active environment: field resolves to
  `Nothing` and falls through to env vars; no error is reported.

**Complexity Notes:** Medium. Requires YAML union type parsing (string | object).
The `(<|>)` merge pattern is simple but the environment map resolution adds a layer
of indirection that must be exercised in tests with multiple environments.

---

## Testing Requirements

- Unit tests for `resolveRegion` cover all five cases: explicit setting, `AWS_REGION`,
  `AWS_DEFAULT_REGION`, fallthrough to error, and priority ordering.
- Unit tests for `detectCredentialSources` cover all credential source types and
  combinations: static env, temporary env, web identity, container (ECS), container
  (generic), profile (all four sources), and assume-role wrapping each base source.
- Unit tests for `credentialDisplayName` and `sourceDisplayName` cover single sources,
  assume-role-wrapped sources, and multi-source override display strings.
- Unit tests for `determineProfile` cover all four priority levels.
- Unit tests for `mergeAwsSettings` verify that CLI opts override stack-args for all
  three fields and that `no-profile`/`no-role` sentinels suppress stack-args values.
- Unit tests for environment map parsing verify string/object union type, key lookup,
  missing key fallthrough, and YAML parse errors.
- Integration tests (mock AWS) for `createAwsEnv` verify that:
  - `setEnv "AWS_PROFILE"` is called before `Amazonka.discover` when profile is set.
  - `STS.fromAssumedRole` is called with the correct ARN and session name `"iidy"`.
  - Region is applied to the returned env.
- Tests for `getCallerIdentity` verify the `("unknown", "unknown")` fallback on any
  exception type.
- Tests for NTP time provider verify fallback to system time on connection failure and
  correct NTP-to-Unix epoch conversion.
- All AWS tests use mock fixtures; no real AWS calls are permitted in the test suite.
- The error message for missing region is tested for exact string content.

## Cross-References

- `src/Iidy/Aws/Config.hs` — primary implementation: `createAwsEnv`, `resolveRegion`,
  `detectCredentialSources`, `credentialDisplayName`
- `src/Iidy/Aws/CredentialSource.hs` — `CredentialSource` ADT, `CredentialSourceStack`,
  `AwsSettings`, `AwsOpts`, `mergeAwsSettings`
- `src/Iidy/Aws/Sts.hs` — `getCallerIdentity` with graceful fallback
- `src/Iidy/Aws/Time.hs` — `ReliableTimeProvider` (NTP), `SystemTimeProvider`
- `src/Iidy/Cfn/CommandMetadata.hs` — `constructCommandMetadata`, `createFinalCommandSummary`
- `src/Iidy/Types/AwsSettings.hs` — `AwsSettings`, `AwsOpts`, env-map parsing
- `docs/dev/aws-configuration.md` — developer guide covering the same subsystem
- `notes/phases/phase-13-research/` — live AWS verification research notes
- `DIVERGENCES.md` — known CLI behavioral differences from Rust iidy (help formatting,
  error color detection)
- PRD 07: Error Display (error formatting pipeline that surfaces AWS errors)
- PRD 13: CloudFormation Write Operations (commands that use `ReliableTimeProvider`)
