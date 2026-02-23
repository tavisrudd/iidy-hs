# Import Types

Import locations appear as values in the `$imports` section of a preprocessed YAML document. Each value is a string that identifies where to load content from and how to parse it. See [yaml-preprocessing.md](yaml-preprocessing.md) for how `$imports` fits into document structure.

---

## file

Load a YAML or JSON file from the local filesystem. Paths are resolved relative to the importing document's location.

**Syntax:** `path/to/file.yaml`, `./relative/path.yaml`, `/absolute/path.yaml`, `file:path/to/file.yaml`

The `file:` prefix is optional. File content is parsed as YAML or JSON based on the file extension.

**Example:**

```yaml
$imports:
  vpc: ./vpc-stack-outputs.yaml
  global: /etc/myapp/global-config.yaml
  same_dir: shared/constants.yaml
```

**Notes:** This import type is restricted to local templates. Remote templates (loaded from S3, HTTP, or HTTPS) cannot use `file:` imports.

---

## env

Read a value from an environment variable.

**Syntax:** `env:VAR_NAME`, `env:VAR_NAME:default-value`

If the variable is not set and no default is provided, preprocessing fails with an error. The default value is everything after the second colon, so colons are allowed in the default.

**Examples:**

```yaml
$imports:
  deploy_env: env:DEPLOY_ENV
  region: env:AWS_REGION:us-east-1
  db_url: env:DATABASE_URL:postgres://localhost:5432/myapp
```

**Notes:** Returns a string. Restricted to local templates; remote templates cannot read environment variables.

---

## git

Read information from the current git repository.

**Syntax:** `git:branch`, `git:sha`, `git:describe`

| Subtype | Equivalent command | Example output |
|---|---|---|
| `git:branch` | `git rev-parse --abbrev-ref HEAD` | `main` |
| `git:sha` | `git rev-parse HEAD` | `a3d955c8f...` |
| `git:describe` | `git describe --always --dirty --tags` | `v1.4.2-3-ga3d955c-dirty` |

**Example:**

```yaml
$imports:
  branch: git:branch
  sha: git:sha
  version: git:describe
```

**Notes:** Returns a string. Restricted to local templates.

---

## random

Generate a random value at preprocessing time.

**Syntax:** `random:dashed-name`, `random:name`, `random:int`

| Subtype | Description | Example output |
|---|---|---|
| `random:dashed-name` | adjective-noun pair with a dash | `clever-eagle` |
| `random:name` | adjective-noun pair without a dash | `clevereagle` |
| `random:int` | integer between 1 and 999 | `742` |

**Example:**

```yaml
$imports:
  stack_suffix: random:dashed-name
  batch_id: random:int
```

**Notes:** A new value is generated each time preprocessing runs. Do not use this in contexts where stable values are required across runs.

---

## filehash

Compute a SHA256 hash of a file's contents.

**Syntax:** `filehash:path/to/file`, `filehash-base64:path/to/file`

Use `filehash:` for a hex-encoded digest and `filehash-base64:` for a base64-encoded digest. Paths are resolved relative to the importing document.

Prefix the path with `?` to allow a missing file without error. A missing file returns the string `FILE_MISSING`.

**Examples:**

```yaml
$imports:
  lambda_hash: filehash:dist/handler.zip
  asset_hash_b64: filehash-base64:dist/handler.zip
  optional_hash: filehash:?dist/optional-asset.zip
```

**Notes:** Useful for detecting when a deployed artifact has changed. Restricted to local templates.

---

## s3

Load a YAML or JSON document from S3. Requires AWS credentials.

**Syntax:** `s3://bucket-name/path/to/object.yaml`

Content is parsed as YAML or JSON based on the object key's extension.

**Example:**

```yaml
$imports:
  shared_config: s3://my-infra-bucket/configs/shared-networking.yaml
  account_limits: s3://my-infra-bucket/accounts/prod/limits.json
```

**Notes:** AWS credentials must be available in the environment or via the configured profile. Templates loaded from S3 are considered remote and cannot use local import types.

---

## http / https

Fetch a YAML or JSON document from an HTTP or HTTPS endpoint. Requires a full URL.

**Syntax:** `http://host/path`, `https://host/path`

Content is parsed as YAML or JSON based on the URL path's extension.

**Example:**

```yaml
$imports:
  service_config: https://config-api.internal.example.com/v1/services/payments.yaml
  feature_flags: https://releases.example.com/flags/prod.json
```

**Notes:** Templates loaded from HTTP or HTTPS are considered remote and cannot use local import types. Relative imports within a remote template inherit the parent's base URL. See [SECURITY.md](SECURITY.md) for the full remote template security model.

---

## cfn

Read data from a CloudFormation stack. Requires AWS credentials.

**Syntax:**

| Format | Returns |
|---|---|
| `cfn:stack-name.OutputKey` | Value of a stack output (legacy shorthand) |
| `cfn:output:stack-name/OutputKey` | Value of a stack output |
| `cfn:output:stack-name` | All stack outputs as a YAML mapping |
| `cfn:export:ExportName` | Value of a named CloudFormation export |
| `cfn:parameter:stack-name/Key` | Value of a stack parameter |
| `cfn:parameter:stack-name` | All stack parameters as a YAML mapping |
| `cfn:tag:stack-name/Key` | Value of a stack tag |
| `cfn:tag:stack-name` | All stack tags as a YAML mapping |
| `cfn:resource:stack-name/LogicalId` | Resource object for a logical resource ID |
| `cfn:resource:stack-name` | All stack resources as a YAML mapping keyed by logical ID |
| `cfn:stack:stack-name` | Entire stack as a mapping with `Outputs`, `Parameters`, and `Tags` keys |

The `cfn:stack-name.OutputKey` dot syntax is a backward-compatible shorthand for `cfn:output:stack-name/OutputKey`.

When looking up a specific field (output, parameter, tag, or resource), the result is either a string value or a resource object. When no field key is given, the result is a YAML mapping of all values.

Resource objects returned by `cfn:resource:` contain `LogicalResourceId`, `PhysicalResourceId`, `ResourceType`, and `ResourceStatus` fields.

**Examples:**

```yaml
$imports:
  # Stack outputs
  vpc_id: cfn:networking-stack.VpcId
  vpc_id_canonical: cfn:output:networking-stack/VpcId
  all_outputs: cfn:output:networking-stack

  # Named exports
  cert_arn: cfn:export:acm-wildcard-cert-arn

  # Stack parameters
  db_instance_class: cfn:parameter:db-stack/InstanceClass
  all_params: cfn:parameter:db-stack

  # Stack tags
  environment: cfn:tag:my-stack/Environment
  all_tags: cfn:tag:my-stack

  # Stack resources
  bucket_info: cfn:resource:my-stack/AssetsBucket
  all_resources: cfn:resource:my-stack

  # Entire stack
  full_stack: cfn:stack:networking-stack
```

**Notes:** The stack must exist in the current account and region. When looking up a specific field, it must be present in the stack, otherwise preprocessing fails.

---

## ssm

Read a single parameter from AWS Systems Manager Parameter Store. Requires AWS credentials.

**Syntax:** `ssm:/parameter/path`, `ssm:/parameter/path:json`, `ssm:/parameter/path:yaml`

SecureString parameters are always decrypted. Without a format suffix the raw string value is returned. Append `:json` or `:yaml` to parse the value as structured data.

**Examples:**

```yaml
$imports:
  db_password: ssm:/myapp/prod/db/password
  feature_flags: ssm:/myapp/prod/feature-flags:json
  rate_limits: ssm:/myapp/prod/rate-limits:yaml
```

**Notes:** The parameter must exist in the current account and region. Requires `ssm:GetParameter` permission and, for SecureString parameters, the relevant KMS decrypt permission.

---

## ssm-path

Read all parameters under an SSM path prefix. Requires AWS credentials.

**Syntax:** `ssm-path:/parameter/path`, `ssm-path:/parameter/path:json`, `ssm-path:/parameter/path:yaml`

Returns a mapping where each key is the parameter name relative to the path prefix and each value is the parameter's value. The retrieval is recursive and SecureString parameters are always decrypted.

Append `:json` or `:yaml` to parse each parameter value as structured data.

**Examples:**

```yaml
$imports:
  db_config: ssm-path:/myapp/prod/db
  # results in a mapping like:
  # host: db.internal.example.com
  # port: "5432"
  # name: myapp_prod
```

```yaml
$imports:
  service_configs: ssm-path:/myapp/prod/services:json
  # each parameter value is parsed as JSON before being placed in the mapping
```

**Notes:** Requires `ssm:GetParametersByPath` permission on the path prefix. For KMS-encrypted parameters, the relevant decrypt permission is also required.

---

## Security Restrictions

Local templates (loaded from the filesystem) can use any import type. Remote templates (loaded from S3, HTTP, or HTTPS) are restricted.

**Blocked in remote templates:**

- `file:` -- local filesystem access
- `env:` -- environment variable access
- `git:` -- local git repository access
- `filehash:` / `filehash-base64:` -- local file hashing

**Allowed in remote templates:**

- `s3:`, `http:`, `https:` -- remote content
- `cfn:` -- CloudFormation outputs and exports
- `ssm:`, `ssm-path:` -- Parameter Store
- `random:` -- random value generation

Relative imports within a remote template resolve using the parent's scheme. A relative path `./sibling.yaml` inside an S3 template resolves to an S3 object in the same bucket prefix, not a local file. Explicit local path indicators (`./`, `../`, or an absolute path starting with `/`) are blocked when used from remote templates.

For the full security model, see [SECURITY.md](SECURITY.md).
