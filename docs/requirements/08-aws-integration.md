# PRD: AWS Integration

## Overview

iidy-hs integrates with AWS to authenticate, authorize, and execute CloudFormation operations. The integration covers credential discovery, region resolution,
IAM role assumption, NTP time synchronization for write operations, STS identity retrieval
for metadata, and graceful error handling across all credential failure modes.

This document captures requirements derived from the implemented behavior verified during
live AWS testing. The implementation achieves byte-for-byte behavioral equivalence with the
Rust iidy binary on all credential chain, region resolution, assume-role, and error display
behaviors.

## Technical Context

The AWS configuration subsystem covers: credential discovery, region resolution, env setup,
credential source tracking and display, `getCallerIdentity` with graceful fallback, and NTP
time synchronization. Settings flow from CLI parsing to options merging with stack-args
settings, then to AWS environment creation. No transformer stack wraps credential state;
the AWS environment is passed explicitly via the command context.

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
1. Credential source detection checks `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
   (non-empty value required for both).
2. If both are present and `AWS_SESSION_TOKEN` is also set: source is `EnvironmentVariablesTemporary`.
3. If both are present but no session token: source is `EnvironmentVariablesStatic`.
4. The detected source is placed first in the credential source stack. All detected sources
   are collected in priority order (env vars > web identity > container > profile).
5. The AWS environment is created via the SDK's standard discovery chain, which picks up
   the same env vars for actual API calls.

Note: Credential source detection is for **provenance tracking and display** only. It does
not configure credentials -- that is handled by amazonka's discovery chain or
`ConfigFile.fromFilePath`. The detection result is used to show the user which credential
source is active in command metadata.

**Edge Cases:**
- `AWS_ACCESS_KEY_ID` set but `AWS_SECRET_ACCESS_KEY` absent: treated as no env var
  credentials; falls through to next source in chain.
- Empty string values for credential variables are treated as absent.
- `AWS_SESSION_TOKEN` present without the key pair: no effect on credential source type.

**Error Scenarios:**
- Expired session tokens are detected by AWS service responses after the request is made;
  iidy surfaces the service error with a formatted message.
- Malformed key values are rejected by AWS at request time, not at configuration time.

**Complexity Notes:** Low. Detection is a pure environment check; actual credential loading
is delegated to the SDK discovery chain.

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
1. CLI options are merged over stack-args settings; CLI profile wins.
2. If `--profile=no-profile`, the profile setting is cleared, suppressing stack-args.
3. If a profile name is resolved, `ConfigFile.fromFilePath` is used to pass it
   programmatically to the SDK. The process environment (`AWS_PROFILE`) is NOT mutated
   (thread-safety consideration). If no profile is resolved, `Amazonka.discover` is
   used, which picks up `AWS_PROFILE` from the environment if set.
4. Credential source detection reads `AWS_PROFILE` from the environment and records the
   profile name and source for display (provenance tracking only, not credential loading).
5. Profile priority: CLI flag > stack-args > `AWS_PROFILE` env var > default.

```pseudocode
createAwsEnv(detectionCtx, settings):
  credStack = detectCredentialSources(detectionCtx)
  env = case settings.profile of
    Just profile -> newEnv(fromFilePath(profile, "~/.aws/credentials", "~/.aws/config"))
    Nothing      -> newEnv(discover)  -- picks up AWS_PROFILE from env if set
  region = resolveRegion(settings.region)
  env.region = region
  if settings.assumeRoleArn is Just arn:
    env = STS.fromAssumedRole(arn, "iidy", env)
  return (env, credStack)

determineProfile(ctx, envProfile):
  -- For display/provenance tracking only
  case (ctx.cliProfile, ctx.stackArgsProfile, envProfile) of
    (Just p, _, _) -> ProfileInfo(p, CLI flag)
    (_, Just p, _) -> ProfileInfo(p, stack-args)
    (_, _, Just p) -> ProfileInfo(p, AWS_PROFILE)
    _              -> ProfileInfo("default", default)
```

**Edge Cases:**
- Profile names with spaces or special characters are passed to `ConfigFile.fromFilePath`.
- If the named profile does not exist in `~/.aws/credentials`, SDK discovery fails at
  the point of the first AWS API call with a credential error.
- Setting `AWS_PROFILE` externally before running iidy is equivalent to providing no
  `--profile` flag — the env var is used as the third-priority fallback.
- `--profile=no-profile` is the only way to explicitly disable a profile set in stack-args;
  there is no `--no-profile` boolean flag.

**Error Scenarios:**
- Unknown profile name: no error at startup; fails at first AWS call, error surfaced as
  a formatted message.
- Profile file permission errors: propagated by the SDK at discovery time.

**Complexity Notes:** Medium. The profile must be passed to `ConfigFile.fromFilePath`
(not via environment mutation) for thread safety. The `no-profile` sentinel value requires
convention-based handling in the settings merge logic.

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
- Assumed-role credentials are automatically refreshed in the background via the SDK's
  role refresh mechanism; no manual refresh is required.
- The credential display shows the role ARN and the base source:
  `assume-role arn:aws:iam::123456789:role/MyRole via profile 'default' (default)`
- The CLI `--assume-role-arn` flag wins over the stack-args `AssumeRoleARN` field.

**Logic Flow:**
1. CLI assume-role ARN is merged over stack-args value; CLI wins.
2. If `--assume-role-arn=no-role`, the ARN setting is cleared.
3. The base AWS environment is fully configured (region, profile) first.
4. If an assume-role ARN is set, STS `AssumeRole` is called with session name `"iidy"`,
   returning a new AWS environment backed by auto-refreshing temporary credentials.
5. The credential source stack wraps the base source with the assume-role info for display.
6. The display formatter renders the wrapped source recursively.

```pseudocode
-- Assume-role wrapping in detectCredentialSources:
applyAssumeRole(sources, ctx):
  case (ctx.cliAssumeRoleArn, ctx.stackArgsAssumeRoleArn) of
    (Just arn, _) ->
      -- CLI ARN wins; wrap the active (first) source
      replace sources[0] with AssumeRoleCredential {
        base = sources[0], arn = arn, source = AssumeRoleCliFlag
      }
    (_, Just arn) ->
      -- Stack-args ARN used if no CLI ARN
      replace sources[0] with AssumeRoleCredential {
        base = sources[0], arn = arn, source = AssumeRoleStackArgs
      }
    _ -> sources  -- no wrapping

-- Display rendering (recursive):
sourceDisplayName(AssumeRoleCredential info) =
  "assume-role " + info.arn + " via " + sourceDisplayName(info.base)
sourceDisplayName(ProfileCredential info) =
  "profile '" + info.name + "' (" + info.source + ")"
sourceDisplayName(EnvironmentVariablesStatic) =
  "environment variables (AWS_ACCESS_KEY_ID)"
```

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
- STS service unavailable: propagated as a service error.

**Complexity Notes:** Medium-high. The base environment must be fully configured (region,
profile) before assume-role is applied. The STS `AssumeRole` call makes a real network
request at startup for write operations.

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
1. CLI region is merged over stack-args region; CLI wins.
2. Region resolution is called with the merged value.
3. If region is set: use it directly.
4. If not set: check `AWS_REGION` env var.
5. If still not set: check `AWS_DEFAULT_REGION` env var.
6. If still not set: fail with a multi-line error message listing all sources.
7. The resolved region is applied to the AWS environment.

**Edge Cases:**
- Malformed region strings (e.g., `"us-east-"`) are passed to `Amazonka.Region'` without
  validation; AWS will reject them at the first API call.
- `AWS_REGION` and `AWS_DEFAULT_REGION` both set: `AWS_REGION` wins.
- Stack-args `Region` set to an environment map with no matching key: resolves to `Nothing`,
  falls through to env vars.
- `--region` provided alongside stack-args `Region`: CLI always wins.

**Region Resolution (pseudocode):**

```pseudocode
resolveRegion(mergedRegion):
  -- mergedRegion = CLI region ?? stack-args region (already merged before this call)
  if mergedRegion is Just r: return Region(r)
  envRegion = lookupEnv("AWS_REGION")
  if envRegion is Just r: return Region(r)
  envDefault = lookupEnv("AWS_DEFAULT_REGION")
  if envDefault is Just r: return Region(r)
  fail("""
    No AWS region configured. Please specify a region via:
      - CLI flag: --region us-east-1
      - Stack args: Region: us-east-1
      - Environment variable: AWS_REGION or AWS_DEFAULT_REGION
      - AWS config file: ~/.aws/config
  """)
```

Note: The error message mentions `~/.aws/config` as a user hint, but the code does NOT
read the AWS config file for region resolution. Region is resolved only from: explicit
setting > `AWS_REGION` > `AWS_DEFAULT_REGION`. The config file mention is for user
guidance (profile-based region lookup is handled implicitly by amazonka when a profile
is active, not by iidy's region resolution code).

**Error Scenarios:**
- No region configured anywhere: error raised as IO exception with the multi-line message
  above. Caught and displayed by the top-level error handler.

**Complexity Notes:** Low. Pure priority chain with no network calls.

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
- If NTP fails (timeout, network error, parse error), iidy falls back to system time
  silently (no warning is emitted to stderr).
- NTP epoch (seconds since 1900-01-01) is correctly converted to Unix epoch
  (seconds since 1970-01-01) using the 70-year offset of 2,208,988,800 seconds.
- No NTP call is made for read-only commands.

**Logic Flow:**

```pseudocode
timeProviderForOperation(op):
  if isReadOnlyOperation(op): return systemTimeProvider  -- plain getCurrentTime
  else: return reliableTimeProvider                       -- NTP with fallback

reliableNow():
  r1 = tryNtp()
  if r1 is Just t: return t
  r2 = tryNtp()
  if r2 is Just t: return t
  return getCurrentTime()  -- system clock fallback, no warning

tryNtp():
  try:
    result = timeout(2_000_000 microseconds, queryNtp())
    case result of
      Just (Just t) -> return Just t
      _             -> return Nothing
  catch IOException: return Nothing     -- silent catch

queryNtp():
  resolve "pool.ntp.org" port 123 (UDP/Datagram)
  send 48-byte SNTP request (LI=0, Version=4, Mode=3, first byte = 0x23)
  recv 48 bytes
  parse transmit timestamp at bytes 40-47:
    secs = bigEndianWord32(bytes[40..43])
    frac = bigEndianWord32(bytes[44..47])
    if secs < 2208988800: return Nothing  -- before Unix epoch = malformed
    unixSecs = secs - 2208988800
    return posixSecondsToUTCTime(unixSecs + frac / 2^32)

-- Time providers also provide tpStartTime = now() - 500ms (safe ordering margin)
```

**Edge Cases:**
- NTP server unreachable (firewall, air-gapped environment): silent fallback to system
  time; no user-visible error or warning.
- NTP response with an unparseable packet (wrong size, zero transmit timestamp): treated
  as a parse failure, falls back to system time. No plausibility check is performed on
  the returned timestamp beyond the "before Unix epoch" check.
- Multiple write operations in the same command invocation: NTP is queried once at
  startup and the result is reused.
- Start time includes a 500ms backward offset (`tpStartTime = now - 0.5s`) for safe
  event ordering.

**Error Scenarios:**
- NTP query timeout after both retries: silent fallback to system time (no stderr output).
- UDP socket creation failure (restricted environments): caught silently, system time used.

**Complexity Notes:** Medium. Requires a custom SNTP client implementation because no
suitable library is available. The NTP-to-Unix epoch conversion must handle the 1900/1970
difference correctly to avoid timestamp errors.

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
  `"unknown"` for both account ID and ARN rather than failing the command. A warning
  is printed to stderr: `"Warning: STS GetCallerIdentity failed: <error>"`.
- When multiple credential sources are detected (e.g., env vars present but profile
  used via assume-role), the active source and overridden sources are both listed.

**Credential Source Data Model:**

```haskell
data CredentialSource
    = EnvironmentVariablesStatic        -- AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
    | EnvironmentVariablesTemporary      -- above + AWS_SESSION_TOKEN
    | ProfileCredential ProfileInfo      -- named profile with source tracking
    | AssumeRoleCredential AssumeRoleInfo -- wraps a base source with role ARN
    | ContainerCredentialsEcs           -- AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
    | ContainerCredentialsGeneric       -- AWS_CONTAINER_CREDENTIALS_FULL_URI
    | WebIdentityToken                   -- AWS_WEB_IDENTITY_TOKEN_FILE
    | InstanceMetadata                   -- EC2 instance metadata
    | UnknownCredentialSource

newtype CredentialSourceStack = CredentialSourceStack
    { cssSources :: [CredentialSource]  -- index 0 = active (highest precedence)
    }

data CredentialDetectionContext = CredentialDetectionContext
    { cdcCliProfile              :: Maybe Text
    , cdcStackArgsProfile        :: Maybe Text
    , cdcCliAssumeRoleArn        :: Maybe Text
    , cdcStackArgsAssumeRoleArn  :: Maybe Text
    }
```

**Logic Flow:**
1. AWS environment creation returns both the configured AWS environment and the credential
   source stack.
2. The credential source stack is a list where index 0 is the active source.
3. Display formatting:
   - Single source: just the source name.
   - Multiple sources: `"<active> (overriding <s1> and <s2>)"`.
4. `getCallerIdentity` calls STS `GetCallerIdentity` and returns `(accountId, arnText)` or
   `("unknown", "unknown")` on any `Amazonka.Error`, printing a warning to stderr.
5. Command metadata is assembled from the context, options, and STS response.
6. The renderer emits the metadata block before the main operation output.

**Credential Detection Cascade (pseudocode):**

```pseudocode
detectCredentialSources(ctx):
  -- Check environment variables in priority order
  hasAccessKey     = nonEmpty(env "AWS_ACCESS_KEY_ID")
  hasSecretKey     = nonEmpty(env "AWS_SECRET_ACCESS_KEY")
  hasSessionToken  = nonEmpty(env "AWS_SESSION_TOKEN")
  hasWebIdentity   = nonEmpty(env "AWS_WEB_IDENTITY_TOKEN_FILE")
  hasContainerEcs  = nonEmpty(env "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
  hasContainerGen  = nonEmpty(env "AWS_CONTAINER_CREDENTIALS_FULL_URI")
  envProfile       = env "AWS_PROFILE"

  sources = concat [
    -- 1. Static/temporary env var credentials (highest priority)
    if hasAccessKey && hasSecretKey && hasSessionToken:
      [EnvironmentVariablesTemporary]
    elif hasAccessKey && hasSecretKey:
      [EnvironmentVariablesStatic]
    else: [],

    -- 2. Web identity token
    [WebIdentityToken | hasWebIdentity],

    -- 3. Container credentials
    [ContainerCredentialsEcs | hasContainerEcs],
    [ContainerCredentialsGeneric | hasContainerGen],

    -- 4. Profile (always present as fallback)
    [ProfileCredential(determineProfile(ctx, envProfile))]
  ]

  -- Apply assume-role wrapper if specified (CLI wins over stack-args)
  case (ctx.cliAssumeRoleArn, ctx.stackArgsAssumeRoleArn) of
    (Just arn, _) -> wrap sources[0] with AssumeRoleCredential(base=sources[0], arn, CliFlag)
    (_, Just arn) -> wrap sources[0] with AssumeRoleCredential(base=sources[0], arn, StackArgs)
    _             -> no wrapping

  return CredentialSourceStack(sources)
```

**Edge Cases:**
- Assume-role wrapping an env var source: display reads
  `"assume-role arn:...:role/X via environment variables (AWS_ACCESS_KEY_ID)"`.
- Profile source with source `ProfileDefault` displays `"profile 'default' (default)"`.
- `getCallerIdentity` is called after the full AWS environment (including assume-role) is
  configured, so it reflects the assumed role identity rather than the base identity.

**Error Scenarios:**
- `sts:GetCallerIdentity` denied by IAM policy: caught, `("unknown", "unknown")` returned,
  warning printed to stderr, command proceeds normally.
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
- AWS service error responses are extracted from the SDK exception type and displayed
  with the HTTP status code and error message, not as raw exception text.
- Credential errors (missing, expired, insufficient permissions) are displayed with
  context about which operation failed.
- Errors during assume-role (STS `AccessDenied`, invalid ARN) are shown before any
  CloudFormation operation begins.
- STS `GetCallerIdentity` failures do not block command execution; they degrade
  gracefully to unknown identity display.
- All AWS errors are written to stderr; successful output goes to stdout (or the
  configured output destination).

**Logic Flow:**
1. Top-level error handler catches all exceptions.
2. SDK service errors are pattern-matched to extract HTTP status and error message text.
3. For service errors: HTTP status and message text are formatted.
4. For IO exceptions (including the missing-region error): the message string is
   formatted directly.
5. Output goes to stderr.
6. Process exits with a non-zero exit code.

**Edge Cases:**
- Expired temporary credentials detected mid-operation (after the first successful call):
  the next AWS call fails; the error is surfaced like any other service error.
- Credential error during STS assume-role: the error is thrown before any CloudFormation
  operation starts.
- Multiple overlapping errors (e.g., region missing AND no credentials): only the first
  error encountered in the setup sequence is reported.

**Error Scenarios:**
- `NoCredentialSources`: SDK discovery found no credentials anywhere.
- `ExpiredTokenException`: session token has expired; user must refresh.
- `AccessDeniedException`: IAM policy denies the requested operation.
- Network timeout connecting to AWS endpoint: propagated as an IO exception.

**Complexity Notes:** Medium. Requires pattern-matching on the SDK's exception hierarchy
to extract service error details. The region error is an IO exception; the message format
must be preserved through exception propagation.

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
1. Stack-args YAML is parsed.
2. For each of `Profile`, `Region`, `AssumeRoleARN`: the field value is parsed as either
   a plain string or an environment map (object with string values).
3. If an environment map, the active environment name is looked up in the map.
4. The resolved optional value is stored in the settings.
5. CLI options are merged over resolved stack-args values; CLI wins.

**Environment Map Resolution (pseudocode):**

```pseudocode
-- POST-PREPROCESSING (resolveEnvMaps in loadStackArgs):
resolveEnvMapField(obj, key, env):
  case obj[key] of
    Object(envMap) ->
      case envMap[env] of
        Just (String s) -> replace obj[key] with String s
        Just nonString  -> ERROR "must map environments to strings"
        Nothing         -> ERROR "environment '<env>' not found in <key> map"
    String _  -> pass through (already scalar)
    Null      -> pass through
    absent    -> pass through
    other     -> ERROR "must be a string or an environment map"

-- PRE-PREPROCESSING BOOTSTRAP (extractRawAwsFromAst):
resolveRawField(name, pairs, environment):
  case lookupField(name, pairs) of
    Nothing         -> Nothing
    AstNull         -> Nothing
    AstPlainString  -> Just text
    AstMapping(map) -> lookupTextField(environment, map)  -- Nothing if key absent (SILENT)
    other           -> Nothing
```

**Important**: The two-pass system has different error semantics for missing environment keys:
- Bootstrap pass (pre-preprocessing): missing key returns `Nothing` (silent fallthrough)
- Full pass (post-preprocessing): missing key returns an error

**Edge Cases:**
- Environment map with uppercase keys vs. lowercase active environment name: key
  lookup is case-sensitive; mismatches result in error (full pass) or `Nothing` (bootstrap).
- Nested environment maps are not supported; values must be plain strings.
- Stack-args `Profile: no-profile` (plain string): treated as the profile named
  `"no-profile"`, not as suppression; only the CLI `--profile=no-profile` flag suppresses.
- Environment map with a key matching `"no-profile"` is valid and would set the profile
  to the string `"no-profile"`.

**Error Scenarios:**
- YAML parse error in the environment map (non-string value): reported as a stack-args
  validation error before any AWS configuration is attempted.
- Environment map key absent for the active environment in full pass: error
  `"environment '<env>' not found in <key> map"`.
- Environment map key absent in bootstrap pass: silent `Nothing`, falls through to CLI
  or env var sources.

**Complexity Notes:** Medium. Requires YAML union type parsing (string | object).
The `(<|>)` merge pattern is simple but the environment map resolution adds a layer
of indirection that must be exercised in tests with multiple environments.

---

### US-08-009: Bootstrap AWS environment for stack-args preprocessing

**As a** Developer using SSM/CFN/S3 imports in stack-args.yaml, **I want to** iidy to
automatically create a bootstrap AWS environment before preprocessing begins, **so that**
import resolution can access AWS services even before the full stack-args are loaded.

**Acceptance Criteria:**
- Before preprocessing stack-args.yaml, a first pass extracts raw AWS settings
  (Profile, Region, AssumeRoleARN) directly from the YAML AST without running the
  preprocessing pipeline.
- These raw settings are merged with CLI settings to create a bootstrap AWS environment.
- The bootstrap environment is passed to the preprocessor to enable SSM, CFN, and S3
  import types.
- If the first pass fails to parse the YAML, empty settings are returned (the full
  loading pass will report the error properly).

**Logic Flow:**

```pseudocode
extractRawAwsFromFile(argsfilePath, environment):
  content = readFile(argsfilePath)
  ast = parseYaml(content)
  if parse fails: return AwsSettings(Nothing, Nothing, Nothing)
  return extractRawAwsFromAst(ast, environment)

extractRawAwsFromAst(ast, environment):
  -- For each of Profile, Region, AssumeRoleARN:
  --   Look up the key in the top-level mapping
  --   If AstPlainString or AstTemplatedString: return Just text
  --   If AstMapping (env map): lookup environment key in sub-mapping
  --     Found: return Just text
  --     Not found: return Nothing   (NOTE: silent, unlike post-preprocessing)
  --   If AstNull or absent: return Nothing
  profile      = resolveRawField("Profile", ast.pairs, environment)
  region       = resolveRawField("Region", ast.pairs, environment)
  assumeRoleArn = resolveRawField("AssumeRoleARN", ast.pairs, environment)
  return AwsSettings(profile, region, assumeRoleArn)
```

**Edge Cases:**
- Environment map with missing key in bootstrap pass: returns `Nothing` (silent fallthrough),
  unlike the full pass which returns an error.
- Unparseable YAML in bootstrap pass: returns empty settings, defers error to full loading.

---

### US-08-010: Apply global SSM configuration

**As a** Platform Engineer, **I want to** configure iidy behavior globally via SSM
Parameter Store, **so that** organization-wide defaults (notification ARNs, template
approval policies) can be managed centrally without modifying individual stack-args files.

**Acceptance Criteria:**
- After stack-args are loaded but before the main CloudFormation operation runs, iidy
  fetches all parameters under `/iidy/` from SSM Parameter Store (with decryption).
- Recognized parameters modify the loaded StackArgs:
  - `/iidy/default-notification-arn`: the ARN value is appended to `saNotificationArns`.
  - `/iidy/disable-template-approval`: if value is `"true"` (case-insensitive) and
    `saApprovedTemplateLocation` is set, it is cleared. A message is printed to stderr.
- If no parameters exist under `/iidy/`, StackArgs passes through unchanged (no warning).
- AWS errors (auth, network, throttling) emit a warning to stderr but do not fail the
  operation. The original StackArgs is returned.
- Async exceptions are not caught.
- Pagination is handled: all pages of SSM results are consumed.

**Logic Flow:**

```pseudocode
applyGlobalConfiguration(awsEnv, stackArgs):
  result = try:
    params = fetchParametersByPath(awsEnv, "/iidy/", withDecryption=true)
  catch Amazonka.Error as ex:
    hPutStrLn(stderr, "Warning: failed to load global config from SSM: " + formatError(ex))
    return stackArgs

  for (name, value) in params:
    case name of
      "/iidy/default-notification-arn" ->
        stackArgs.notificationArns = (stackArgs.notificationArns ?? []) ++ [value]
      "/iidy/disable-template-approval" ->
        if toLower(value) == "true" and stackArgs.approvedTemplateLocation is set:
          hPutStrLn(stderr, "Disabling template approval based on global ... parameter store configuration")
          stackArgs.approvedTemplateLocation = Nothing
      _ -> no-op (unrecognized parameter silently ignored)

  return stackArgs
```

**Edge Cases:**
- SNS topic validation is not performed on the notification ARN (amazonka-sns is
  incompatible with the current GHC/base version). Invalid ARNs will produce a
  downstream AWS error when used.
- Multiple calls to `applyGlobalConfiguration` would append the notification ARN
  multiple times.

---

## Testing Requirements

- Unit tests for region resolution cover all five cases: explicit setting, `AWS_REGION`,
  `AWS_DEFAULT_REGION`, fallthrough to error, and priority ordering.
- Unit tests for credential source detection cover all credential source types and
  combinations: static env, temporary env, web identity, container (ECS), container
  (generic), profile (all four sources), and assume-role wrapping each base source.
- Unit tests for credential display name formatting cover single sources, assume-role-
  wrapped sources, and multi-source override display strings.
- Unit tests for profile determination cover all four priority levels.
- Unit tests for settings merging verify that CLI options override stack-args for all
  three fields and that `no-profile`/`no-role` sentinels suppress stack-args values.
- Unit tests for environment map parsing verify string/object union type, key lookup,
  missing key fallthrough, and YAML parse errors.
- Integration tests (mock AWS) verify that:
  - Profile is passed via `ConfigFile.fromFilePath` (not environment mutation) when configured.
  - STS `AssumeRole` is called with the correct ARN and session name `"iidy"`.
  - The resolved region is applied to the returned AWS environment.
- Tests for `getCallerIdentity` verify the `("unknown", "unknown")` fallback and warning
  output on any `Amazonka.Error` exception type.
- Tests for the NTP time provider verify fallback to system time on connection failure and
  correct NTP-to-Unix epoch conversion. Verify no stderr output on NTP failure.
- Tests for `applyGlobalConfiguration` verify:
  - `/iidy/default-notification-arn` appends to notification list.
  - `/iidy/disable-template-approval` clears approved template location when "true".
  - AWS errors produce warning but return original StackArgs.
  - Empty parameter list passes through unchanged.
- Tests for bootstrap AWS extraction (`extractRawAwsFromFile`) verify:
  - Plain string and environment map resolution.
  - Missing env key returns Nothing (not error).
  - Parse failure returns empty settings.
- All AWS tests use mock fixtures; no real AWS calls are permitted in the test suite.
- The error message for missing region is tested for exact string content.

## Cross-References

- `docs/dev/aws-configuration.md` — developer guide covering the same subsystem
- `notes/archive/phase-13-research/` — live AWS verification research notes
- `DIVERGENCES.md` — known CLI behavioral differences from Rust iidy
- PRD-07: Error Handling — error formatting pipeline that surfaces AWS errors
- PRD-05: CloudFormation Operations — commands that use the NTP time provider
