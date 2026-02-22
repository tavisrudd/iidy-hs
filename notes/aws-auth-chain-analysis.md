# AWS Auth Chain Precedence Analysis

## Summary

Rust vs Haskell comparison of credential resolution, profile handling,
assume-role, and region configuration. Three critical gaps found.

## 1. Region Resolution

### Precedence Order

| Priority | Source | Rust | Haskell | Match? |
|----------|--------|------|---------|--------|
| 1 | CLI `--region` flag | ✅ | ✅ | ✅ |
| 2 | stack-args `Region` field | ✅ | ✅ | ✅ |
| 3 | `AWS_REGION` env var | ✅ | ✅ | ✅ |
| 4 | `AWS_DEFAULT_REGION` env var | ✅ | ✅ | ✅ |
| 5 | Profile `~/.aws/config` region | ✅ | ❌ | **GAP** |
| 6 | Default fallback | **ERROR** | **us-east-1** | **GAP** |

### Gap Details

**Rust**: If no region configured anywhere, returns an error: "No AWS region
configured. Set via --region, stack-args Region, AWS_REGION, or AWS_DEFAULT_REGION."

**Haskell**: Falls back silently to `Amazonka.NorthVirginia` (us-east-1).
This masks misconfiguration.

**Rust also**: Reads region from the profile's config in `~/.aws/config`.
Haskell skips this step (amazonka may do it internally via `discover`).

### Fix

Change `resolveRegion Nothing` to check if amazonka resolved a region from
config, only use hardcoded us-east-1 as absolute last resort, or consider
erroring like Rust does.

## 2. Profile Handling

### Precedence Order

| Priority | Source | Rust | Haskell | Match? |
|----------|--------|------|---------|--------|
| 1 | CLI `--profile` | ✅ | ❌ (display only) | **CRITICAL GAP** |
| 2 | stack-args `Profile` | ✅ | ❌ (display only) | **CRITICAL GAP** |
| 3 | `AWS_PROFILE` env var | ✅ (AWS SDK) | ✅ (amazonka.discover) | ✅ |
| 4 | Default `"default"` | ✅ | ✅ | ✅ |

### Gap Details

**CRITICAL**: In Haskell, `createAwsEnv` always uses `Amazonka.newEnv
Amazonka.discover` without passing the profile. The profile from CLI/stack-args
is only used for provenance display (which credential source is shown in
CommandMetadata), but is **NOT used for actual credential loading**.

If a user runs `iidy-hs create-stack --profile production stack-args.yaml`,
the `--profile production` flag is:
1. Detected correctly → displays "profile 'production' (CLI flag)" ✅
2. **NOT actually used** for credentials → still uses whatever `discover` finds ❌

**Rust**: Explicitly configures the SDK's profile provider with the
specified profile name before loading credentials.

### Fix

Must configure amazonka's credential chain to use the specified profile:
```haskell
-- When awsProfile is specified, override the profile in Env
env <- case awsProfile settings of
  Just profile -> do
    -- Set AWS_PROFILE before discovery, or configure Amazonka with profile
    ...
  Nothing -> Amazonka.newEnv Amazonka.discover
```

Options for amazonka:
1. Set `AWS_PROFILE` env var before calling `discover` (side-effect approach)
2. Use `Amazonka.newEnvFromManager` with explicit credential configuration
3. Override the auth in the returned Env

## 3. Assume-Role-ARN Handling

### Precedence Order

| Priority | Source | Rust | Haskell | Match? |
|----------|--------|------|---------|--------|
| 1 | CLI `--assume-role-arn` | ✅ | ❌ (display only) | **CRITICAL GAP** |
| 2 | stack-args `AssumeRoleARN` | ✅ | ❌ (display only) | **CRITICAL GAP** |
| 3 | Profile `role_arn` in config | ✅ | ❌ | GAP |

### Gap Details

**CRITICAL**: Same pattern as profile — assume-role-arn from CLI/stack-args
is detected for display but **never actually executed**. No STS AssumeRole
call is made.

**Rust**: Wraps the base credential provider with an AssumeRoleProvider:
1. Load base credentials (from env vars, profile, etc.)
2. If assume-role-arn specified, create AssumeRoleProvider that:
   - Uses base credentials to call STS:AssumeRole
   - Returns temporary credentials for the assumed role
   - Auto-refreshes when credentials expire

**Haskell**: Only records `AssumeRoleCredential` in the CredentialSourceStack
for display purposes. No STS:AssumeRole call happens.

### Fix

Must implement STS AssumeRole credential wrapping:
```haskell
-- After creating base env, wrap with AssumeRole if specified
env' <- case awsAssumeRoleArn settings of
  Just roleArn -> do
    -- Use base env to call STS:AssumeRole
    -- Return new env with temporary credentials
    assumeRole env roleArn
  Nothing -> pure env
```

## 4. Credential Source Detection

Both Rust and Haskell check the same environment variables in the same order:
1. `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (± `AWS_SESSION_TOKEN`)
2. `AWS_WEB_IDENTITY_TOKEN_FILE`
3. `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`
4. `AWS_CONTAINER_CREDENTIALS_FULL_URI`
5. Profile-based credentials
6. Instance metadata (via SDK)

This matches. ✅

## 5. Stack-Args AWS Settings Merging

Both use the same `CLI <|> stack-args` pattern (CLI wins). ✅

Both support environment-specific maps in stack-args:
```yaml
Profile:
  development: dev-profile
  production: prod-profile
```
This matches. ✅

## 6. Other Gaps

### AWS_SDK_LOAD_CONFIG
**Rust**: Sets `AWS_SDK_LOAD_CONFIG=true` if `~/.aws/` directory exists
(causes AWS SDK to load `~/.aws/config` in addition to `~/.aws/credentials`).
**Haskell**: Does not set this. Amazonka may handle this differently.
Severity: LOW — amazonka likely reads config by default.

### Profile role_arn
**Rust**: Parses `~/.aws/config` to check if the active profile has a
`role_arn` setting (for profiles that automatically assume a role).
**Haskell**: `piProfileRoleArn = Nothing` — never parsed.
Severity: MEDIUM — affects users whose profiles auto-assume roles.

## Severity Summary

| Gap | Severity | Impact |
|-----|----------|--------|
| Profile not applied to credentials | **CRITICAL** | `--profile` flag ignored for actual auth |
| Assume-role not executed | **CRITICAL** | `--assume-role-arn` flag ignored for actual auth |
| Region defaults to us-east-1 | **HIGH** | Masks misconfiguration |
| Profile role_arn not parsed | MEDIUM | Auto-assume profiles don't work |
| AWS_SDK_LOAD_CONFIG not set | LOW | Config file may not load |

## Recommended Fix Phase

Add a new sub-phase (13.X or new Phase 15) to:
1. Wire `--profile` into amazonka credential loading
2. Implement STS AssumeRole credential wrapping
3. Consider erroring on missing region instead of defaulting
4. Parse profile `role_arn` from `~/.aws/config`
