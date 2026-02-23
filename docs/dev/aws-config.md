# AWS Configuration Resolution

Developer reference for how iidy-hs resolves AWS region, credentials, and
profile settings. The process has two stages: iidy-specific merging (Stage 1)
followed by the standard AWS SDK credential chain (Stage 2).

---

## Overview

```
               Stage 1 (iidy-specific)             Stage 2 (amazonka)
  CLI flags  ─────┐                                ┌──────────────────┐
                   ├─ mergeAwsSettings ─ AwsSettings ─┤                  │
  stack-args ─────┘                                │ Amazonka.newEnv  │
                                                   │   Amazonka.discover│
  Environment ────── detectCredentialSources ──────│  (default chain) │
  variables          (provenance tracking only)    └──────────────────┘
```

**Stage 1** merges CLI flags and stack-args.yaml fields into a single
`AwsSettings` value. CLI flags always take priority over argsfile fields.

**Stage 2** passes `AwsSettings` to `createAwsEnv`, which calls
`Amazonka.newEnv Amazonka.discover` for the actual credential chain, then
applies iidy's region override on top.

Credential detection (`detectCredentialSources`) runs in parallel with
Stage 2. It does *not* configure credentials -- it inspects the environment to
determine which source is active, producing a `CredentialSourceStack` used for
audit trail display (e.g., "assume-role arn:... via profile 'default'").

---

## Region Resolution

`resolveRegion` determines the AWS region. Priority order (highest first):

| Priority | Source                          | Code path                         |
|----------|---------------------------------|-----------------------------------|
| 1        | `--region` CLI flag             | `AwsSettings.awsRegion = Just r`  |
| 2        | `Region` field in stack-args    | merged via `mergeAwsSettings`     |
| 3        | `AWS_REGION` environment var    | `lookupEnv "AWS_REGION"`          |
| 4        | `AWS_DEFAULT_REGION` env var    | `lookupEnv "AWS_DEFAULT_REGION"`  |
| 5        | Hardcoded default: `us-east-1`  | `Amazonka.NorthVirginia`          |

CLI and stack-args are merged before `resolveRegion` is called, so from
`resolveRegion`'s perspective it sees either `Just region` (from whichever
source won) or `Nothing` (fall through to env vars / default).

```haskell
resolveRegion :: Maybe Text -> IO Amazonka.Region
resolveRegion (Just r) = pure (textToRegion r)
resolveRegion Nothing  = ...  -- checks env vars, falls back to us-east-1
```

---

## Credential Detection

`detectCredentialSources` inspects environment variables to build a
`CredentialSourceStack` -- a list of `CredentialSource` values ordered by
priority. The head of the list is the active source.

Priority order (highest first):

| Priority | Source                      | Env var(s) checked                              |
|----------|-----------------------------|--------------------------------------------------|
| 1        | Temporary env credentials   | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` + `AWS_SESSION_TOKEN` |
| 2        | Static env credentials      | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (no session token)    |
| 3        | Web identity token          | `AWS_WEB_IDENTITY_TOKEN_FILE`                    |
| 4        | ECS container credentials   | `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`         |
| 5        | Generic container creds     | `AWS_CONTAINER_CREDENTIALS_FULL_URI`             |
| 6        | Profile (always present)    | Falls back to `"default"` if no profile set      |

Multiple sources can be present simultaneously. The list captures all detected
sources; the first element is active, and the rest are "overridden" sources
shown for diagnostic purposes.

This detection is for *provenance display only*. The actual credential loading
is handled by `Amazonka.discover`, which has its own priority chain that
broadly matches this order.

---

## Profile Resolution

`determineProfile` resolves which named profile to use. Priority:

| Priority | Source                   | Detection context field   | `ProfileSource` value      |
|----------|--------------------------|---------------------------|----------------------------|
| 1        | `--profile` CLI flag     | `cdcCliProfile`           | `ProfileCliFlag`           |
| 2        | `Profile` in stack-args  | `cdcStackArgsProfile`     | `ProfileStackArgs`         |
| 3        | `AWS_PROFILE` env var    | (looked up at detection)  | `ProfileAwsProfileEnvVar`  |
| 4        | Hardcoded default        | (none)                    | `ProfileDefault`           |

The resolved profile is always included in the credential source stack as a
`ProfileCredential` fallback, regardless of whether higher-priority sources
(env vars, container, etc.) are also present.

```haskell
determineProfile :: CredentialDetectionContext -> Maybe Text -> ProfileInfo
determineProfile ctx envProfile =
  let (name, source) = case (cdcCliProfile ctx, cdcStackArgsProfile ctx, envProfile) of
        (Just p, _, _) -> (p, ProfileCliFlag)
        (_, Just p, _) -> (p, ProfileStackArgs)
        (_, _, Just p) -> (p, ProfileAwsProfileEnvVar)
        _              -> ("default", ProfileDefault)
  in ProfileInfo { piName = name, piSource = source, piProfileRoleArn = Nothing }
```

---

## Assume-Role Wrapping

When `--assume-role-arn` is specified (via CLI or stack-args `AssumeRoleARN`
field), the active credential source is wrapped in an `AssumeRoleCredential`.
CLI takes precedence over stack-args.

The wrapping replaces the head of the source list:

```
Before: [EnvironmentVariablesStatic, ProfileCredential ...]
After:  [AssumeRoleCredential (AssumeRoleInfo EnvironmentVariablesStatic "arn:..." AssumeRoleCliFlag),
         ProfileCredential ...]
```

This allows the display to show chained provenance:
`"assume-role arn:aws:iam::123:role/Foo via environment variables (static)"`

---

## Credential Display

`credentialDisplayName` renders a human-readable string from a
`CredentialSourceStack`, used in command metadata and error context.

Examples:

| Stack                                                | Display                                                          |
|------------------------------------------------------|------------------------------------------------------------------|
| `[ProfileCredential ("default", ProfileDefault)]`    | `profile 'default' (default)`                                    |
| `[EnvironmentVariablesTemporary, ProfileCredential…]`| `environment variables (temporary) (overrides: profile 'default' (default))` |
| `[AssumeRoleCredential (EnvStatic, arn, CliFlag)]`   | `assume-role arn:... via environment variables (static)`         |

```haskell
credentialDisplayName :: CredentialSourceStack -> Text
sourceDisplayName :: CredentialSource -> Text
```

---

## Stack-Args Environment

When loading a stack-args file, iidy injects a `$envValues` map into the
argsfile data before deserialization. This map is available to Handlebars
templates within the stack-args.

### $envValues structure

```yaml
$envValues:
  region: "us-east-1"          # resolved region
  environment: "staging"       # environment name from CLI
  iidy:
    command: "create-stack"    # current CFN operation
    environment: "staging"
    region: "us-east-1"
    profile: "my-profile"     # only present if profile is set
```

Built by `buildEnvValues` using the merged `AwsSettings`:

```haskell
buildEnvValues :: Text -> CfnOperation -> AwsSettings -> Value
```

### AWS settings from stack-args

The argsfile can specify three AWS-related fields at the top level:

| Field            | Maps to                       |
|------------------|-------------------------------|
| `Profile`        | `AwsSettings.awsProfile`      |
| `Region`         | `AwsSettings.awsRegion`       |
| `AssumeRoleARN`  | `AwsSettings.awsAssumeRoleArn`|

These are extracted by `extractAwsSettings` and merged with CLI settings via
`mergeAwsSettings` (CLI wins on conflict):

```haskell
mergeAwsSettings :: AwsSettings -> AwsSettings -> AwsSettings
mergeAwsSettings cli argsfile = AwsSettings
  { awsProfile       = awsProfile cli <|> awsProfile argsfile
  , awsRegion        = awsRegion cli <|> awsRegion argsfile
  , awsAssumeRoleArn = awsAssumeRoleArn cli <|> awsAssumeRoleArn argsfile
  }
```

---

## Key Types

```haskell
-- src/Iidy/Aws/CredentialSource.hs

data AwsSettings = AwsSettings
  { awsProfile       :: !(Maybe Text)
  , awsRegion        :: !(Maybe Text)
  , awsAssumeRoleArn :: !(Maybe Text)
  }

data CredentialDetectionContext = CredentialDetectionContext
  { cdcCliProfile             :: !(Maybe Text)
  , cdcStackArgsProfile       :: !(Maybe Text)
  , cdcCliAssumeRoleArn       :: !(Maybe Text)
  , cdcStackArgsAssumeRoleArn :: !(Maybe Text)
  }

data CredentialSource
  = EnvironmentVariablesStatic
  | EnvironmentVariablesTemporary
  | ProfileCredential !ProfileInfo
  | AssumeRoleCredential !AssumeRoleInfo
  | ContainerCredentialsEcs
  | ContainerCredentialsGeneric
  | WebIdentityToken
  | InstanceMetadata
  | UnknownCredentialSource

newtype CredentialSourceStack = CredentialSourceStack
  { cssSources :: [CredentialSource]   -- head = active source
  }

data ProfileInfo = ProfileInfo
  { piName           :: !Text
  , piSource         :: !ProfileSource
  , piProfileRoleArn :: !(Maybe Text)
  }

data AssumeRoleInfo = AssumeRoleInfo
  { ariBaseSource :: !CredentialSource
  , ariRoleArn    :: !Text
  , ariSource     :: !AssumeRoleSource
  }

data ProfileSource
  = ProfileCliFlag | ProfileStackArgs | ProfileAwsProfileEnvVar | ProfileDefault

data AssumeRoleSource
  = AssumeRoleCliFlag | AssumeRoleStackArgs
```

---

## Key Files

| File                                  | Purpose                                       |
|---------------------------------------|-----------------------------------------------|
| `src/Iidy/Aws/Config.hs`             | `createAwsEnv`, `resolveRegion`, `detectCredentialSources`, `credentialDisplayName` |
| `src/Iidy/Aws/CredentialSource.hs`    | All credential-related types (`CredentialSource`, `AwsSettings`, etc.)              |
| `src/Iidy/Aws/Sts.hs`                | `getCallerIdentity` for provenance display in error contexts                        |
| `src/Iidy/Cfn/StackArgsLoader.hs`     | `loadStackArgs`, `mergeAwsSettings`, `extractAwsSettings`, `$envValues` injection   |
| `src/Iidy/Cli.hs`                     | `AwsOpts` CLI option types                                                          |
| `app/Main.hs`                         | `cliToAwsSettings`, wiring CLI opts into the AWS config pipeline                    |

---

## amazonka Integration Notes

- Uses **amazonka 2.0** which relies on `DuplicateRecordFields`.
- Import operation-specific modules with unique qualifiers to avoid field
  selector ambiguity (e.g., `import qualified Amazonka.STS.GetCallerIdentity as STS`).
- Use `OverloadedRecordDot` for reading fields from response values
  (e.g., `resp.account`).
- `Amazonka.newEnv Amazonka.discover` handles the actual credential chain.
  iidy does not manually configure credentials -- it relies entirely on
  amazonka's default discovery, then layers on region overrides.
- STS `GetCallerIdentity` is used for error context (e.g., showing which
  account/ARN when a stack is absent). It catches all exceptions and falls
  back to `("unknown", "unknown")`.
