# Security Model for YAML Import System

This document describes the security model implemented in iidy-hs's YAML
preprocessing import system to prevent malicious remote templates from
accessing local resources.

## Overview

The YAML import system processes untrusted templates that may originate from
remote sources (S3, HTTP/HTTPS). The security model distinguishes between
**local templates** (loaded from the local filesystem) and **remote templates**
(loaded from S3 or HTTP/HTTPS URLs), applying different restrictions to each.

Local templates are trusted: they already execute in the user's local context,
so no additional restrictions apply. Remote templates are untrusted: they are
restricted from accessing local resources such as files, environment variables,
and git metadata.

## Local-Only Import Types

The following 5 import types are **forbidden from remote templates**:

| Import Type      | Description                       | Security Risk                          |
|------------------|-----------------------------------|----------------------------------------|
| `file:`          | Local filesystem access           | Could read sensitive files             |
| `env:`           | Local environment variables       | Could access secrets and credentials   |
| `git:`           | Local git repository access       | Could extract repository information   |
| `filehash:`      | File hashing (local files)        | Could scan filesystem structure        |
| `filehash-base64:` | File hashing with base64 encoding | Could scan filesystem structure     |

These types correspond to `ImportFile`, `ImportEnv`, `ImportGit`,
`ImportFilehash`, and `ImportFilehashBase64` in the Haskell source. The
`isLocalOnly` function in `Types.hs` classifies them.

## Remote-Allowed Import Types

The following 6 import types are **allowed from any context**, including
remote templates:

| Import Type       | Description                    | Use Case                              |
|-------------------|--------------------------------|---------------------------------------|
| `s3:`             | S3 objects                     | Access other S3-stored configurations |
| `http:`/`https:`  | HTTP endpoints                 | Fetch configuration from web APIs     |
| `cfn:`            | CloudFormation stacks/exports  | Dynamic AWS resource references       |
| `ssm:`            | SSM parameters                 | Centralized configuration management  |
| `ssm-path:`       | SSM parameter paths            | Bulk parameter retrieval              |
| `random:`         | Random value generation        | Generate unique identifiers           |

## Relative Import Behavior

When a template uses a relative import (no explicit type prefix), the import
inherits the type of the parent template:

```yaml
# From s3://bucket/configs/app.yaml
$imports:
  database: "database.yaml"  # Resolves to s3://bucket/configs/database.yaml
```

Explicit local path indicators are blocked from remote templates. Paths
starting with `./`, `../`, or `/` are treated as `file:` imports and rejected:

```yaml
# From s3://bucket/config.yaml — these are ALL REJECTED:
$imports:
  bad1: "./local.yaml"      # Local path from remote
  bad2: "../local.yaml"     # Local path from remote
  bad3: "/abs/local.yaml"   # Absolute local path from remote
```

## Base Path Resolution

The system derives base paths from the parent template's location to resolve
relative imports across different contexts.

### Local File Paths

- `/home/app/configs/main.yaml` -> `/home/app/configs/`
- `./configs/app.yaml` -> `./configs/`
- `config.yaml` -> `` (empty — current directory)

### S3 URLs

- `s3://bucket/file.yaml` -> `s3://bucket/`
- `s3://bucket/configs/app.yaml` -> `s3://bucket/configs/`

### HTTP/HTTPS URLs

- `https://example.com/file.yaml` -> `https://example.com/`
- `https://example.com/configs/app.yaml` -> `https://example.com/configs/`

The `isRemoteBase` function determines whether a base location is remote by
checking for `s3://`, `http://`, or `https://` prefixes. The `parseTypePrefix`
function extracts the type prefix from an import location, treating paths
with `./`, `../`, or `/` prefixes as implicit `file:` imports.

## Threat Model

### What This Protects Against

1. **Credential Theft** — Prevents remote templates from reading environment
   variables containing AWS keys, tokens, or other secrets via `env:` imports.

2. **File System Scanning** — Blocks remote templates from reading local files
   or probing directory structure via `file:`, `filehash:`, and
   `filehash-base64:` imports.

3. **Information Disclosure** — Prevents extraction of git repository metadata
   (branch, commit hash, tags) via `git:` imports.

4. **Privilege Escalation** — Stops remote templates from accessing local
   resources beyond their intended scope. A template fetched from S3 cannot
   reach into the deployer's local filesystem.

### What This Allows

1. **Legitimate Composition** — Remote templates can compose from other remote
   sources (S3-to-S3, HTTPS-to-S3, etc.).

2. **Relative Imports** — Templates can reference related files in the same
   remote context without absolute URLs.

3. **AWS Integration** — Remote templates can access CloudFormation outputs
   and SSM parameters for dynamic configuration.

4. **Local Flexibility** — Local templates retain full import capabilities
   for all trusted operations.

## CLI Control: `--no-remote-imports`

The `--no-remote-imports` flag disables all network-fetching import types at
the CLI level. When set, any `http:`, `https:`, or `s3:` import returns an
error instead of fetching content.

**Blocked by `--no-remote-imports`:**

- `http:` / `https:` — arbitrary HTTP fetches (SSRF risk)
- `s3:` — arbitrary S3 object fetches

**NOT blocked by `--no-remote-imports`:**

- `cfn:`, `ssm:`, `ssm-path:` — these are AWS API calls that go through the
  AWS SDK with IAM authentication. They require credentials and are bounded
  by IAM policy, not open HTTP. They are gated by `--profile` / AWS
  credential configuration, not by the remote imports flag.
- `env:`, `file:`, `git:`, `filehash:`, `random:` — local operations.

This flag is orthogonal to the remote-base trust model described above. The
trust model prevents remote *templates* from reading local resources. The
`--no-remote-imports` flag prevents local *users* from fetching remote
content, useful in air-gapped or egress-restricted environments.

The default is `--remote-imports` (allowed). Use `--no-remote-imports` to
restrict.

## Implementation Notes

Security validation is centralized in `parseImportType` in
`src/Iidy/Yaml/Imports/Types.hs`. This function:

1. Extracts the type prefix from the import location (`parseTypePrefix`).
2. Maps the prefix to an `ImportType` constructor.
3. Checks whether the base location is remote (`isRemoteBase`).
4. Rejects the import if both conditions hold: the base is remote AND the
   import type is local-only (`isLocalOnly`).

Individual import loaders live under `src/Iidy/Yaml/Imports/Loaders/`:

- `File.hs` — Local filesystem imports
- `Env.hs` — Environment variable imports
- `Git.hs` — Git metadata imports
- `S3.hs` — S3 object imports
- `Http.hs` — HTTP/HTTPS imports
- `Cfn.hs` — CloudFormation stack/export imports
- `Ssm.hs` — SSM parameter imports
- `Random.hs` — Random value generation

Base path threading occurs in `src/Iidy/Yaml/Engine.hs`, where `baseLocation`
is passed through the preprocessing pipeline and propagated to child imports.
The `TagContext` in `src/Iidy/Yaml/Resolution/Context.hs` carries the
`tcInputUri` field, which tracks the current template's origin for resolution.

When a security violation is detected, the system returns a clear error:

```
Import type file is not allowed from remote templates
```

The implementation follows the principle of secure by default: remote templates
are restricted unless the import type is explicitly classified as remote-safe.
