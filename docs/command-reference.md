# Command Reference

iidy ("Is it done yet?") is a CloudFormation deployment tool. It wraps the AWS CloudFormation API with
a preprocessing pipeline for YAML templates, a structured watch loop for stack events, and change
visibility tooling (diffs, changesets, drift detection).

## Global Options

These options apply to every command and may be placed before or after the subcommand name.

| Option | Default | Description |
|--------|---------|-------------|
| `-e, --environment <ENV>` | `development` | Load environment-based settings (AWS profile, region) from stack-args.yaml |
| `--region <REGION>` | | AWS region override. Overrides stack-args.yaml and environment config |
| `--profile <PROFILE>` | | AWS profile override. Use `--profile=no-profile` to ignore stack-args.yaml and rely on `AWS_*` env vars |
| `--assume-role-arn <ARN>` | | AWS role to assume before executing the operation. Use `--assume-role-arn=no-role` to ignore stack-args.yaml |
| `--client-request-token <TOKEN>` | auto-generated UUID | Idempotency token for CloudFormation operations. Auto-generated if omitted |
| `--output-mode <MODE>` | `interactive` in terminals | Output mode: `interactive`, `plain`, or `json` |
| `--color <WHEN>` | `auto` | ANSI color output: `auto`, `always`, or `never` |
| `--theme <THEME>` | `auto` | Color theme: `auto`, `light`, `dark`, or `high-contrast` |
| `--debug` | false | Log debug information to stderr |
| `--log-full-error` | false | Log full error information to stderr |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error |
| 130 | Cancelled (user responded No to a prompt, or Ctrl-C received) |

## Idempotency Tokens

CloudFormation mutations (create, update, delete, changeset) accept an optional client request
token for idempotency. iidy always provides one, auto-generating a UUID for each operation so you
never need to think about it. If a network timeout or transient failure causes a retry,
CloudFormation recognizes the duplicate token and returns the result of the original operation
rather than applying the change twice.

For multi-step operations (e.g., `create-or-update` with `--changeset` creates a changeset then
executes it), iidy derives deterministic sub-tokens from the primary token using SHA256 hashing.
The same primary token always produces the same derived tokens, so retrying the entire operation
is safe -- each step gets the same idempotency token it had on the first attempt.

The token and any derived tokens are displayed in the Command Metadata section of every operation's
output for traceability. You can supply your own semantically meaningful token via
`--client-request-token` -- for example, a release tag or CI build ID -- which then also serves
as the base for any derived sub-tokens.

---

### Stack Lifecycle

## create-stack

Creates a new CloudFormation stack from a stack-args.yaml file. The argsfile specifies the stack
name, template path, parameters, tags, and other configuration. iidy preprocesses the template
before submission. The command watches stack events until the operation completes or fails.

```
iidy create-stack <argsfile> [--stack-name <NAME>] [global options]
```

| Option | Description |
|--------|-------------|
| `<argsfile>` | Path to stack-args.yaml (required) |
| `--stack-name <NAME>` | Override the stack name defined in the argsfile |

```
iidy -e staging create-stack stack-args.yaml
iidy create-stack stack-args.yaml --stack-name my-app-v2
```

## update-stack

Updates an existing CloudFormation stack. Before submitting the update, iidy shows a diff of
template and parameter changes and prompts for confirmation unless `--yes` is given. Pass
`--changeset` to route the update through a changeset for manual review before execution.

```
iidy update-stack <argsfile> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<argsfile>` | | Path to stack-args.yaml (required) |
| `--stack-name <NAME>` | | Override the stack name from argsfile |
| `--lint-template <BOOL>` | | Enable or disable template linting before update |
| `--changeset` | false | Create a changeset instead of updating directly; requires manual execution |
| `--yes` | false | Skip the confirmation prompt |
| `--diff` | true | Show a template diff before updating |
| `--stack-policy-during-update <FILE>` | | Stack policy to apply during this update only |

```
iidy update-stack stack-args.yaml --yes
iidy -e prod update-stack stack-args.yaml --changeset
iidy update-stack stack-args.yaml --stack-policy-during-update policy.json
```

## create-or-update

Creates the stack if it does not exist, or updates it if it does. This is the primary command for
continuous deployment pipelines where the stack's existence state is unknown or variable. Accepts
the same options as `update-stack`.

```
iidy create-or-update <argsfile> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<argsfile>` | | Path to stack-args.yaml (required) |
| `--stack-name <NAME>` | | Override the stack name from argsfile |
| `--lint-template <BOOL>` | | Enable or disable template linting |
| `--changeset` | false | Use a changeset for the update path |
| `--yes` | false | Skip the confirmation prompt |
| `--diff` | true | Show a template diff before updating |
| `--stack-policy-during-update <FILE>` | | Stack policy to apply during update only |

```
iidy -e prod create-or-update stack-args.yaml --yes
```

## delete-stack

Deletes a CloudFormation stack after interactive confirmation. Unlike the lifecycle commands above,
this command takes a stack name directly rather than a stack-args.yaml path. Use `--fail-if-absent`
in scripts that require the stack to exist before deletion.

```
iidy delete-stack <stackname> [options] [global options]
```

| Option | Description |
|--------|-------------|
| `<stackname>` | Name or ID of the stack to delete (required) |
| `--role-arn <ARN>` | IAM role ARN for CloudFormation to assume during deletion |
| `--retain-resources <RESOURCE>...` | Logical resource IDs to retain after deletion |
| `--yes` | Skip the confirmation prompt |
| `--fail-if-absent` | Exit with an error if the stack does not exist |

```
iidy delete-stack my-app-staging
iidy delete-stack my-app-staging --yes --retain-resources MyS3Bucket
```

---

### Changesets

## create-changeset

Creates a CloudFormation changeset without executing it. Use this to inspect what changes will be
made before committing to an update. Optionally pass `--watch` to tail changeset creation events
rather than returning immediately.

```
iidy create-changeset <argsfile> [changeset-name] [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<argsfile>` | | Path to stack-args.yaml (required) |
| `[changeset-name]` | | Name for the changeset; auto-generated if omitted |
| `--stack-name <NAME>` | | Override the stack name from argsfile |
| `--watch` | false | Watch changeset creation events |
| `--watch-inactivity-timeout <SECS>` | 180 | Seconds of inactivity before the watch loop exits |
| `--description <DESC>` | | Human-readable description for the changeset |

```
iidy create-changeset stack-args.yaml my-changeset-v3 --watch
iidy -e prod create-changeset stack-args.yaml --description "Add Lambda function"
```

## exec-changeset

Executes a previously created changeset, applying the proposed changes to the stack. The changeset
must already exist and be in a reviewable state. After execution, iidy watches stack events until
the operation completes.

```
iidy exec-changeset <argsfile> <changeset-name> [options] [global options]
```

| Option | Description |
|--------|-------------|
| `<argsfile>` | Path to stack-args.yaml (required) |
| `<changeset-name>` | Name of the changeset to execute (required) |
| `--stack-name <NAME>` | Override the stack name from argsfile |

```
iidy exec-changeset stack-args.yaml my-changeset-v3
iidy -e prod exec-changeset stack-args.yaml my-changeset-v3 --stack-name my-app-prod
```

---

### Monitoring

## describe-stack

Shows the current state of a stack including its status, parameters, outputs, and recent events.
Pass `--query` with a JMESPath expression to extract specific fields from the output for scripting.

```
iidy describe-stack <stackname> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<stackname>` | | Name or ID of the stack (required) |
| `--events <N>` | 50 | Number of recent stack events to display |
| `--query <JMESPATH>` | | JMESPath expression to filter output |

```
iidy describe-stack my-app-prod
iidy describe-stack my-app-prod --events 10
iidy describe-stack my-app-prod --query "Outputs[?OutputKey=='ApiUrl'].OutputValue | [0]"
```

## watch-stack

Attaches to a stack that is already being created or updated and tails its events in real time.
Use this when a deployment was started independently (e.g., by a CI system) and you want to
observe progress. The command exits when the operation finishes or when no new events arrive
within the inactivity timeout.

```
iidy watch-stack <stackname> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<stackname>` | | Name or ID of the stack (required) |
| `--inactivity-timeout <SECS>` | 180 | Seconds without new events before exiting |

```
iidy watch-stack my-app-prod
iidy watch-stack my-app-prod --inactivity-timeout 300
```

## describe-stack-drift

Initiates a drift detection operation and displays which stack resources have drifted from their
expected configuration. CloudFormation drift detection can take a minute or more for large stacks;
iidy polls until results are available. Recently cached results may be reused depending on the
`--drift-cache` setting.

```
iidy describe-stack-drift <stackname> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<stackname>` | | Name or ID of the stack (required) |
| `--drift-cache <SECS>` | 300 | Reuse a cached drift result if it is younger than this many seconds |

```
iidy describe-stack-drift my-app-prod
iidy describe-stack-drift my-app-prod --drift-cache 0
```

---

### Information

## list-stacks

Lists all stacks in the current region. Supports filtering by tag, JMESPath expression, or custom
column selection. Useful for auditing environments or finding stacks that match a particular
ownership or application tag.

```
iidy list-stacks [options] [global options]
```

| Option | Description |
|--------|-------------|
| `--tag-filter <KEY=VALUE>...` | Filter stacks by tag key-value pair; may be repeated |
| `--jmespath-filter <EXPR>` | Filter the raw stack list with a JMESPath expression |
| `--query <JMESPATH>` | Apply a JMESPath expression to the output data |
| `--tags` | Include tag columns in the output |
| `--columns <COLS>` | Comma-separated list of columns to display |

```
iidy list-stacks
iidy -e prod list-stacks --tag-filter Team=platform --tag-filter Env=prod
iidy list-stacks --tags --columns Name,Status,Team
```

## get-stack-template

Downloads the template of a live CloudFormation stack and prints it to stdout. The `--stage`
option controls whether to retrieve the original template as submitted or the processed version
after CloudFormation macro transformations.

```
iidy get-stack-template <stackname> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<stackname>` | | Name or ID of the stack (required) |
| `--format <FMT>` | `original` | Output format: `json`, `yaml`, or `original` |
| `--stage <STAGE>` | `original` | Template stage: `original` (as submitted) or `processed` (after transforms) |

```
iidy get-stack-template my-app-prod
iidy get-stack-template my-app-prod --format yaml > template.yaml
iidy get-stack-template my-app-prod --stage processed --format json
```

## get-import

Retrieves and prints an import value directly, without going through a full template render. This
is useful for inspecting what a particular import URI resolves to. See
[import-types.md](import-types.md) for the full list of supported import URI schemes.

```
iidy get-import <import-uri> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<import-uri>` | | Import URI to resolve (required) |
| `--format <FMT>` | `yaml` | Output format: `yaml` or `json` |
| `--query <JMESPATH>` | | JMESPath expression to filter the resolved value |

```
iidy get-import ssm:/myapp/prod/db-password
iidy get-import ./shared-outputs.yaml --query VpcId
iidy get-import env:DATABASE_URL --format json
```

---

### Template Preprocessing

## render

Preprocesses a YAML template (or stack-args file) through iidy's tag and import engine, then
prints the result. Read from stdin by passing `-` as the template path. This command is the
primary way to inspect what a template looks like after iidy's preprocessing without deploying
it. See [yaml-preprocessing.md](yaml-preprocessing.md) for full preprocessing documentation.

```
iidy render <template> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<template>` | | Template file path, or `-` to read from stdin (required) |
| `--outfile <PATH>` | stdout | Write output to this file instead of stdout |
| `--format <FMT>` | `yaml` | Output format: `yaml`, `json`, or `yaml-cloudformation` |
| `--query <JMESPATH>` | | JMESPath expression to filter the rendered output |
| `--overwrite` | false | Allow overwriting an existing outfile |
| `--yaml-spec <VER>` | `auto` | YAML input parsing mode: `auto`, `1.1`, or `1.2`. `auto` detects `%YAML` directives and CloudFormation patterns. `1.1` converts `yes`/`no`/`on`/`off` to booleans; `1.2` treats them as strings |

```
iidy render template.yaml
iidy render template.yaml --format json > template.json
iidy render - < template.yaml --query 'Resources | keys(@)'
iidy render template.yaml --outfile rendered.yaml --overwrite
```

---

### Cost Estimation

## estimate-cost

Submits the stack configuration to the AWS CloudFormation cost estimation API and returns a link
to the AWS Simple Monthly Calculator with pre-populated values. Costs are estimates only and do
not account for data transfer or usage patterns.

```
iidy estimate-cost <argsfile> [options] [global options]
```

| Option | Description |
|--------|-------------|
| `<argsfile>` | Path to stack-args.yaml (required) |
| `--stack-name <NAME>` | Override the stack name from argsfile |

```
iidy estimate-cost stack-args.yaml
iidy -e prod estimate-cost stack-args.yaml --stack-name my-app-prod
```

---

### Template Approval

The template approval workflow gates production deployments on explicit review. It is designed
for organizations where one team (e.g., application developers) authors CloudFormation templates
and another team (e.g., ops, SRE, or security) must approve changes before they reach production.

#### How it works

1. The stack-args.yaml includes an `ApprovedTemplateLocation` field pointing to an S3 prefix
   (e.g., `s3://my-org-approvals/templates/my-app/`).
2. A developer runs `template-approval request`. iidy preprocesses the template through the
   full pipeline (imports, variables, tags, handlebars), computes a SHA256 hash of the processed
   output, and uploads it to `{prefix}/{hash}.pending` in S3.
3. A reviewer runs `template-approval review <s3-url>`. iidy fetches the pending template and
   the most recently approved version, shows a colored diff, and prompts for approval.
4. On approval, iidy copies the pending template to the approved key (removing `.pending`) and
   updates a `latest` reference.
5. At deploy time, iidy re-processes the template, re-hashes it, and checks whether a matching
   approved object exists. If it does, the deployment proceeds. If not, it fails.

Because the hash is computed on the fully-processed template, any change to the source -- including
changes to imported files or resolved variables -- produces a different hash and requires a new
approval. Conversely, once a template is approved, parameter-only changes to stack-args.yaml do
not require re-approval because the template itself has not changed.

#### Security model

The enforcement mechanism is IAM, not application logic. In protected environments (production
accounts/regions), the CloudFormation service role's IAM policy restricts `cloudformation:CreateStack`,
`cloudformation:UpdateStack`, `cloudformation:DeleteStack`, `cloudformation:CreateChangeSet`,
and other mutation operations to templates sourced from the approved S3 location. A template
that has not been approved and copied to that location simply cannot be deployed -- CloudFormation
will reject the API call regardless of what tooling is used.

The actual security gate is the IAM policy on the deploy role. Once those roles and permissions
are in place, iidy's `template-approval` commands make the workflow around them seamless:
developers submit with one command, reviewers see a clear diff and approve with one command,
and deploys just work if the template is approved.

The S3 bucket permissions complete the picture:

- **Developers** need `s3:PutObject` on `.pending` keys to submit requests, but should NOT
  have `s3:PutObject` on the approved (non-pending) keys. This prevents self-approval.
- **Reviewers** need `s3:GetObject` to read pending and approved templates, and `s3:PutObject`
  plus `s3:DeleteObject` to approve (copy to approved key, delete pending).
- **CloudFormation service role** in production needs `s3:GetObject` on the approved keys only.

For cross-account deployments, the `bucket-owner-full-control` ACL is set on uploads so the
bucket owner retains control regardless of which account uploads.

## template-approval request

Submits a template approval request. iidy preprocesses the template, computes its hash, and
uploads it to the pending location in S3. If the template is already approved (same hash), the
command reports this and exits without uploading.

```
iidy template-approval request <argsfile> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<argsfile>` | | Path to stack-args.yaml (required) |
| `--lint-template` | true | Lint the template before requesting approval |
| `--lint-using-parameters` | false | Pass actual parameter values to the linter |

```
iidy template-approval request stack-args.yaml
iidy -e prod template-approval request stack-args.yaml --lint-using-parameters
```

## template-approval review

Opens a pending template approval request and displays the diff for review. The reviewer accepts
or rejects the request interactively. The `--context` option controls how many lines of diff
context are shown.

```
iidy template-approval review <url> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<url>` | | Approval request URL (required) |
| `--context <N>` | 100 | Lines of diff context to display |

```
iidy template-approval review s3://my-org-approvals/templates/my-app/a1b2c3d4.yaml.pending
iidy template-approval review s3://my-org-approvals/templates/my-app/a1b2c3d4.yaml.pending --context 50
```

---

### SSM Parameter Store

The `param` subcommands manage AWS SSM Parameter Store values. They support a `--format` flag
for controlling output:

| Format | Description |
|--------|-------------|
| `simple` | Value only (default). For `get`, prints the raw value. For `get-by-path`, prints a YAML map of path to value. For `get-history`, prints a YAML document with Current and Previous sections showing Value, LastModifiedDate, LastModifiedUser, and Message |
| `json` | Full parameter object including Name, Type, Value, Version, LastModifiedDate, ARN, DataType, and Tags (fetched separately). Pretty-printed JSON |
| `yaml` | Same as `json` but formatted as YAML |

The `--format` flag is independent of the global `--output-mode` flag. Param commands write
directly to stdout rather than going through the data-driven output pipeline used by
CloudFormation commands.

## param set

Creates or updates an AWS SSM Parameter Store parameter. By default the value is stored as a
`SecureString` (KMS-encrypted). Use `--with-approval` to route the change through an approval
workflow before it takes effect.

For `SecureString` parameters, iidy looks up a KMS alias by building a hierarchical path from
the parameter name. Given `/myapp/prod/db-password`, it tries `alias/ssm/myapp/prod/db-password`,
then `alias/ssm/myapp/prod`, then `alias/ssm/myapp`, then `alias/ssm`. If no match is found,
SSM uses the default `aws/ssm` key.

```
iidy param set <path> <value> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<path>` | | SSM parameter path (required) |
| `<value>` | | Parameter value (required) |
| `--type <TYPE>` | `SecureString` | SSM parameter type: `String`, `StringList`, or `SecureString` |
| `--overwrite` | false | Overwrite an existing parameter |
| `--message <MSG>` | | Attach a change description as an `iidy:message` tag |
| `--with-approval` | false | Store as `{path}.pending` and require `param review` before it takes effect |

```
iidy param set /myapp/prod/db-password "s3cr3t" --overwrite
iidy param set /myapp/prod/feature-flag "true" --type String
iidy param set /myapp/prod/api-key "key" --with-approval --message "Rotate API key"
```

## param get

Retrieves a single SSM parameter value. SecureString parameters are decrypted by default.

```
iidy param get <path> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<path>` | | SSM parameter path (required) |
| `--decrypt` | true | Decrypt SecureString parameters |
| `--format <FMT>` | `simple` | Output format: `simple`, `json`, or `yaml` |

```
iidy param get /myapp/prod/db-password
iidy param get /myapp/prod/db-password --format json
iidy param get /myapp/prod/db-password --decrypt=false
```

## param get-by-path

Retrieves all SSM parameters under a path prefix, sorted by name. Use `--recursive` to include
parameters in nested sub-paths. Returns exit code 1 if no parameters are found.

```
iidy param get-by-path <path> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<path>` | | SSM parameter path prefix (required) |
| `--decrypt` | true | Decrypt SecureString parameters |
| `--format <FMT>` | `simple` | Output format: `simple`, `json`, or `yaml` |
| `--recursive` | false | Include parameters in nested sub-paths |

```
iidy param get-by-path /myapp/prod
iidy param get-by-path /myapp --recursive --format yaml
```

## param get-history

Retrieves the version history of an SSM parameter. Output is split into Current (latest version,
with tags) and Previous (all older versions, without tags), sorted by LastModifiedDate ascending.

```
iidy param get-history <path> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<path>` | | SSM parameter path (required) |
| `--decrypt` | true | Decrypt SecureString parameter history |
| `--format <FMT>` | `simple` | Output format: `simple`, `json`, or `yaml` |

```
iidy param get-history /myapp/prod/db-password
iidy param get-history /myapp/prod/db-password --format json
```

## param review

Reviews a pending SSM parameter change that was submitted with `param set --with-approval`.
Shows the current and pending values side by side, displays any `iidy:message` tag, and prompts
for confirmation. On approval, the pending value is promoted to the real path and the `.pending`
parameter is deleted. Tags are copied from the pending parameter to the real one.

Returns exit code 1 if no pending change exists, or 130 if the user declines.

```
iidy param review <path> [global options]
```

| Option | Description |
|--------|-------------|
| `<path>` | SSM parameter path with a pending change (required) |

```
iidy param review /myapp/prod/api-key
```

---

### Utilities

## explain

Prints a human-readable explanation of one or more iidy or CloudFormation error codes.

```
iidy explain <codes>... [global options]
```

| Option | Description |
|--------|-------------|
| `<codes>...` | One or more error codes to explain (e.g., `ERR_2001`) |

```
iidy explain ERR_2001
iidy explain ERR_2001 ERR_2002
```

## completion

Generates a shell completion script for the specified shell and prints it to stdout. Source or
install the output according to your shell's conventions.

```
iidy completion [shell] [global options]
```

| Option | Description |
|--------|-------------|
| `[shell]` | Shell to generate completions for: `bash`, `zsh`, `fish`, or `powershell`. Detects current shell if omitted |

```
iidy completion zsh > ~/.zsh/completions/_iidy
iidy completion bash >> ~/.bashrc
```

---

### Migration and Scaffolding

## lint-template

Validates a CloudFormation template by loading it through the full iidy preprocessing pipeline
and submitting it to the AWS `ValidateTemplate` API. Any preprocessing errors (bad tags, missing
imports, Handlebars syntax) surface during template loading; structural CloudFormation errors are
caught by the API. Returns exit code 0 if the template is valid, 1 if errors are found.

The `--use-parameters` flag is accepted for CLI compatibility but has no effect (the AWS
ValidateTemplate API does not accept parameters).

```
iidy lint-template <argsfile> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<argsfile>` | | Path to stack-args.yaml (required) |
| `--use-parameters` | false | Accepted for compatibility; has no effect |

```
iidy lint-template stack-args.yaml
iidy -e prod lint-template stack-args.yaml
```

## convert-stack-to-iidy

Generates a `stack-args.yaml` and template file from an existing CloudFormation stack, creating
an iidy project directory for a stack that was not originally deployed with iidy. Fetches the
stack's current template, parameters, tags, and configuration from CloudFormation and writes
them to the output directory. Use `--move-params-to-ssm` to convert parameters to SSM references.

```
iidy convert-stack-to-iidy <stackname> <output-dir> [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `<stackname>` | | Name or ID of the stack (required) |
| `<output-dir>` | | Directory to write the generated files (required) |
| `--move-params-to-ssm` | false | Write each parameter value to SSM as SecureString at `/{environment}/{project}/{key}`, then reference them via `!$ ssmParams.{key}` in the generated stack-args.yaml. Requires `--project` or a `project` tag on the stack |
| `--sortkeys` | true | Sort keys in generated YAML files |
| `--project <NAME>` | | Project name for SSM path prefix |

```
iidy convert-stack-to-iidy my-app-prod ./my-app
iidy -e prod convert-stack-to-iidy my-app-prod ./my-app --move-params-to-ssm --project myapp
```

## init-stack-args

Initializes a new `stack-args.yaml` and `cfn-template.yaml` in the specified directory (defaults
to the current directory). Creates a commented template with common fields to help you get
started quickly.

```
iidy init-stack-args [options] [global options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--dir <DIR>` | `.` | Directory in which to create the files |

```
iidy init-stack-args
iidy init-stack-args --dir ./my-new-stack
```

---

## Related Documentation

- [getting-started.md](getting-started.md) -- stack-args.yaml format and project structure
- [yaml-preprocessing.md](yaml-preprocessing.md) -- full reference for iidy's YAML preprocessing tags and import system
- [import-types.md](import-types.md) -- supported import URI schemes for `get-import` and `$imports`
