# PRD: CLI Interface

## Overview

iidy exposes all CloudFormation operations through a single binary with a consistent global
option set and a flat command hierarchy. Every command receives the same global options
(environment, region, profile, role, output mode, color), dispatches to an AWS-specific
implementation, and exits with one of three status codes: 0 (success), 1 (error), or 130
(cancelled).

The CLI is the sole entry point into the system. It owns argument parsing, environment variable
resolution, credential chain setup, and output mode selection before handing control to command
implementations. Behavioral parity with the Rust iidy binary is the acceptance standard: where
this document says "matches Rust oracle," it means byte-for-byte output equivalence on the same
input is the target, with documented divergences as the only permitted exceptions.

## Technical Context

**CLI structure**: The CLI must support a subcommand hierarchy with global options that may
appear before or after the subcommand name. Boolean flags with default-on behavior (e.g.,
`--no-diff`, `--no-decrypt`) must be modeled explicitly as negation flags, since the help
framework may not auto-generate them. Help layout column widths and section titles must match
the Rust oracle output as closely as the chosen framework allows. All command names, flag names,
metavars, and descriptions are identical between implementations.

---

## User Stories

---

### US-01-001: Run any command with global options

**As a** Developer or CI Pipeline, **I want to** pass global flags like `--environment`,
`--region`, `--profile`, `--output-mode`, and `--color` before or after the subcommand name,
**so that** I can control AWS targeting and output format without modifying stack-args.yaml.

**Acceptance Criteria:**

- `--environment <ENV>` (short: `-e`) sets the environment name used to select the matching
  block from stack-args.yaml. Default: `development`.
- `--region <REGION>` sets the AWS region for the session. Overrides the `Region` field in
  stack-args.yaml and the environment block. No default (region is required and must come from
  CLI, stack-args.yaml, or `AWS_REGION`/`AWS_DEFAULT_REGION`; error if absent).
- `--profile <PROFILE>` sets the AWS profile (credential source). Overrides stack-args.yaml
  `Profile`. Passing `--profile=no-profile` explicitly suppresses any profile from stack-args.yaml
  and forces credential resolution from environment variables only.
- `--assume-role-arn <ARN>` causes the CLI to call STS AssumeRole before executing the command.
  Passing `--assume-role-arn=no-role` suppresses any `AssumeRoleARN` from stack-args.yaml.
- `--client-request-token <TOKEN>` provides an explicit idempotency token. CLI help text says
  "up to 64 ASCII characters" (inherited from Rust); the CloudFormation API actually allows
  up to 128 characters. If omitted, a UUID v4 is auto-generated.
- `--output-mode <MODE>` selects the output renderer. Values: `plain`, `interactive`, `json`.
  If omitted, defaults to `interactive` when stdout is a TTY, `plain` otherwise.
- `--color <WHEN>` controls ANSI escape codes. Values: `auto`, `always`, `never`. Default:
  `auto`. `auto` enables color when stdout is a TTY and ANSI is supported. `NO_COLOR` env var
  takes precedence over `auto` and forces `never`. `FORCE_COLOR` env var forces `always` when
  `NO_COLOR` is absent.
- `--theme <THEME>` selects the color palette. Values: `auto`, `light`, `dark`, `high-contrast`.
  Default: `auto`. `IIDY_THEME` env var sets the default. `auto` selects based on terminal
  background detection.
- `--no-remote-imports` disables HTTP and S3 `$imports` (flag; default: remote imports
  enabled). AWS API imports (`cfn:`, `ssm:`, `ssm-path:`) are not affected. Stored
  internally as a boolean where True = imports allowed, False = disallowed.
- `--debug` enables debug logging to stderr (flag, default: false).
- `--log-full-error` prints full error detail to stderr including stack traces (flag, default:
  false).
- `-V, --version` prints `iidy-hs <semver>` and exits 0.
- `-h, --help` prints the custom top-level help and exits 0.
- Global options may appear before or after the subcommand on the command line.
- Invalid values for `--color`, `--theme`, `--output-mode` produce: `error: <message>` on
  stderr, a Usage line, and "For more information, try '--help'."; exit code 1.

**Logic Flow:**

1. Parse args from the command line.
2. If no args or `--help` with no subcommand: render custom top-level help, exit 0.
3. On parse failure: render error in Rust-compatible format, exit 1.
4. On parse success: normalize AWS options (resolve `no-profile`/`no-role` sentinels, generate
   UUID token), then dispatch to command handler.

**Edge Cases:**

- `--profile=no-profile` must be compared literally after parsing; it is not a special sentinel
  at parse time, only at normalization time.
- `--assume-role-arn=no-role` same semantics as above.
- `--output-mode` is `Maybe OutputMode`; the absence of the flag is distinct from `plain`.
- Terminal width for help wrapping is clamped to [60, 120]; falls back to 100 if undetectable.
  The `COLUMNS` env var is not read directly; terminal width is queried from the terminal device.

**Terminal Width and Description Wrapping:**

```pseudocode
detectHelpWidth():
  win = queryTerminalSize()
  if win is Nothing: return 100
  return clamp(win.width, 60, 120)

formatRows(wrapWidth, rows):
  nameWidth = max(0, max(length(name) for each (name, _) in rows))
  availableWidth = max(20, wrapWidth - nameWidth - 4)
  -- descriptions are word-wrapped to availableWidth
```

**Error Scenarios:**

- Unknown subcommand: exit 1, message: `error: Invalid value '<cmd>' for '<COMMAND>'`.
- Missing required positional: exit 1, message lists the missing argument.
- Invalid enum value: exit 1, message names the expected values.

**Complexity Notes:**

- The custom top-level help path short-circuits before standard argument parsing to emit the
  Rust-style top-level help layout rather than the parser framework's default layout.
- Help color detection uses `stdout` TTY status (not stderr), matching Rust behavior for help.
  Error color detection uses `stderr` TTY status (intentional divergence from Rust; see
  DIVERGENCES.md).

---

### US-01-002: Create a stack from stack-args.yaml

**As a** Developer or Platform Engineer, **I want to** create a new CloudFormation stack by
pointing iidy at a stack-args.yaml file, **so that** the stack is created with pre-processed
templates, watched to completion, and I see structured output.

**Acceptance Criteria:**

- Command: `iidy create-stack <ARGSFILE> [--stack-name <NAME>]`
- `<ARGSFILE>` (positional, required): path to stack-args.yaml.
- `--stack-name <NAME>` (optional): overrides the `StackName` field in the argsfile.
- iidy preprocesses the template through the full pipeline (imports, variables, Handlebars tags)
  before submission.
- iidy watches stack events until CREATE_COMPLETE or CREATE_FAILED, emitting structured
  output data for each event.
- On CREATE_COMPLETE: exit 0.
- On CREATE_FAILED: exit 1 with error output.
- On stack already existing: exit 1 with error output naming the existing stack.
- `--client-request-token` is forwarded to the CloudFormation CreateStack API call.
- StackDefinition output is emitted before polling begins.
- CommandMetadata and FinalCommandSummary are emitted at the end of a successful run.

**Logic Flow:**

1. Load and parse argsfile.
2. Override stack name if `--stack-name` provided.
3. Preprocess template.
4. Optionally lint template (if `LintTemplate: true` in argsfile).
5. Upload template to S3 if oversized (> 51,200 bytes body limit).
6. Call CloudFormation CreateStack API.
7. Emit OdStackDefinition.
8. Poll events via watch loop until terminal status.
9. Emit OdCommandMetadata and OdFinalCommandSummary.

**Edge Cases:**

- Argsfile not found: exit 1 with file path in error.
- Template preprocessing error: exit 1 with position information.
- Region missing from all sources: exit 1 with explicit error (no defaulting to us-east-1).

**Error Scenarios:**

- Exit 1 on any AWS API error, with full error message displayed.
- Exit 130 on SIGINT during watch loop.

---

### US-01-003: Update a stack with diff preview and confirmation

**As a** Developer, **I want to** update an existing stack and see a diff of what will change
before confirming, **so that** I can catch unintended changes before they reach AWS.

**Acceptance Criteria:**

- Command: `iidy update-stack <ARGSFILE> [options]`
- `<ARGSFILE>` (positional, required): path to stack-args.yaml.
- `--stack-name <NAME>`: override stack name from argsfile.
- `--lint-template <BOOL>`: override linting on/off (takes a bool value, e.g., `True`/`False`).
- `--changeset` (flag, default: false): route the update through a changeset for manual review.
  When set, creates a changeset then pauses; user must run `exec-changeset` separately.
- `--yes` (flag, default: false): skip the interactive confirmation prompt.
- `--no-diff` (flag, default: diff shown): suppress the template diff display before update.
  `--diff` is not a valid flag name; `--no-diff` disables the default-on behavior.
- `--stack-policy-during-update <POLICY>`: path or inline JSON of a stack policy to apply during
  this update only (passed to CloudFormation UpdateStack).
- When `--yes` is absent: shows a colored diff of template and parameter changes, then prompts
  for confirmation. Declining exits 130.
- On no-changes detected by CloudFormation: CloudFormation returns a `ValidationError` with
  "No updates are to be performed"; this is re-thrown and exits 1 with an informational message.
- On UPDATE_COMPLETE: exit 0. On UPDATE_FAILED or ROLLBACK_COMPLETE: exit 1.
- CommandMetadata and FinalCommandSummary emitted on success.

**Logic Flow:**

1. Load argsfile, resolve stack name.
2. Preprocess template.
3. Fetch current stack template from CloudFormation.
4. Compute diff; display unless `--no-diff`.
5. If not `--yes`: prompt for confirmation; exit 130 on decline.
6. If `--changeset`: create changeset and return; else submit UpdateStack.
7. Poll events to completion.

**Edge Cases:**

- Stack does not exist: exit 1 (use `create-or-update` for idempotent behavior).
- `--lint-template` flag takes a boolean value (e.g., `True`/`False`), not a `--no-lint` negation.

---

### US-01-004: Create or update a stack (smart routing)

**As a** CI Pipeline, **I want to** run a single command regardless of whether the stack exists,
**so that** my pipeline does not need branching logic for first-deploy vs. subsequent deploys.

**Acceptance Criteria:**

- Command: `iidy create-or-update <ARGSFILE> [options]`
- Accepts the same options as `update-stack`.
- If stack does not exist: routes to create path (equivalent to `create-stack`).
- If stack exists and is in a stable state: routes to update path.
- Routing based on `(exists, useChangeset)` — four paths: direct create, direct update,
  CREATE changeset, UPDATE changeset. `ROLLBACK_COMPLETE` stacks are treated as absent.
- Exit codes and output data identical to the underlying create or update path taken.

**Logic Flow:**

1. Load argsfile, preprocess template.
2. Describe stack (may return StackAbsentInfo).
3. Branch: absent -> create; present and stable -> update; present and in-progress -> error.
4. For changeset path: further branch on stack status.

**Edge Cases:**

- Stack in ROLLBACK_COMPLETE: treated as delete-and-recreate by the changeset path.
- Stack in any in-progress state: exit 1 with error naming the current status.

---

### US-01-005: Delete a stack with confirmation

**As a** Platform Engineer, **I want to** delete a CloudFormation stack and be prompted for
confirmation, **so that** accidental deletion is prevented in interactive use.

**Acceptance Criteria:**

- Command: `iidy delete-stack <STACKNAME> [options]`
- `<STACKNAME>` (positional, required): stack name or stack ID. This is the stack name directly,
  not a path to stack-args.yaml.
- `--role-arn <ARN>`: IAM role ARN for CloudFormation to assume during deletion.
- `--retain-resources <RESOURCE>` (repeatable): logical resource IDs to retain. Can be specified
  multiple times.
- `--yes` (flag): skip confirmation prompt.
- `--fail-if-absent` (flag): exit 1 if the stack does not exist. Default: exit 0 with
  informational message when stack is absent.
- Confirmation prompt format: `? Delete stack <NAME>? [y/N]` with `?` in bold-red, stack name
  in bold.
- Declining the prompt (any response other than `y`/`Y`): exit 130 (not exit 1).
- STS caller identity is displayed in the confirmation prompt context.
- On DELETE_COMPLETE: exit 0. On DELETE_FAILED: exit 1.
- Stack absent without `--fail-if-absent`: exit 0, emit OdStackAbsentInfo.

**Logic Flow:**

1. Describe stack; handle absent case.
2. Emit OdStackDefinition with current state.
3. If not `--yes`: display credential context, prompt; exit 130 on decline.
4. Call DeleteStack API.
5. Poll events to DELETE_COMPLETE.

**Error Scenarios:**

- Exit 1 on AWS API error.
- Exit 130 on user declines or SIGINT.

---

### US-01-006: Describe stack state

**As a** Developer or Reviewer, **I want to** see the current status, parameters, outputs, and
recent events of a stack, **so that** I can diagnose a failure or verify a deployment.

**Acceptance Criteria:**

- Command: `iidy describe-stack <STACKNAME> [options]`
- `<STACKNAME>` (positional, required): stack name or ID.
- `--events <N>` (default: 50): number of recent events to display.
- `--query <JMESPATH>` (optional): JMESPath expression applied to the output data structure.
  Filtered result is printed to stdout as YAML.
- Stack absent: exit 1 with OdStackAbsentInfo including STS caller identity context.
- Output includes: stack status, parameters, outputs, recent N events.
- Exit 0 on success regardless of stack status (even ROLLBACK_COMPLETE).

**Edge Cases:**

- `--query` with invalid JMESPath: exit 1 with parse error.
- `--events 0`: show no events (valid).

---

### US-01-006b: Detect stack resource drift

**As a** Platform Engineer, **I want to** detect whether resources in a stack have
drifted from their CloudFormation-managed configuration, **so that** out-of-band changes
are identified before they cause deployment failures.

**Acceptance Criteria:**

- Command: `iidy describe-stack-drift <STACKNAME> [options]`
- `<STACKNAME>` (positional, required): stack name or ID.
- `--drift-cache <SECONDS>` (default: 300): reuse a previous drift detection result if
  the stack's `lastCheckTimestamp` is within this many seconds and the drift status is not
  `NOT_CHECKED`.
- If the cache is valid: skip the `DetectStackDrift` API call and use existing drift data.
- If detection is needed: call `DetectStackDrift`, then poll
  `DescribeStackDriftDetectionStatus` every 3 seconds until detection completes.
- Collect drift results via paginated `DescribeStackResourceDrifts`.
- Filter out `IN_SYNC` resources; only drifted resources are included in the output.
- Emit `OdStackDefinition` before detection begins.
- Emit `OdStatusUpdate` with `"Checking for stack drift..."` when detection is initiated.
- Emit `OdStackDrift` with the list of drifted resources (logical ID, physical ID,
  resource type, drift status, property differences).
- Exit 0 on success (regardless of drift status). Exit 1 if the stack does not exist.
- CommandMetadata and FinalCommandSummary are emitted.

**Logic Flow:**

1. Describe stack; exit 1 if absent.
2. Emit OdStackDefinition.
3. Check drift cache: if within `--drift-cache` window, skip detection.
4. If detection needed: call DetectStackDrift, poll until complete.
5. Collect and filter drift results.
6. Emit OdStackDrift.

**Edge Cases:**

- All resources are `IN_SYNC`: `OdStackDrift` emitted with an empty drifted resources
  list (not an error).
- Cache check with `driftInformation` absent or `NOT_CHECKED`: always triggers detection.
- `--drift-cache 0`: always triggers a fresh detection.

**Error Scenarios:**

- Stack not found: exit 1 with error.
- Drift detection API error: propagated as exception; exit 1.

---

### US-01-007: Watch live stack events

**As a** Developer, **I want to** attach to a stack mid-operation and tail its events in real
time, **so that** I can monitor a deployment started by a CI system or another team member.

**Acceptance Criteria:**

- Command: `iidy watch-stack <STACKNAME> [options]`
- `<STACKNAME>` (positional, required): stack name or ID.
- `--inactivity-timeout <SECONDS>` (default: 180): exit with code 0 if no new events arrive
  within this many seconds.
- In `interactive` output mode: a spinner is shown with elapsed time and time since last event,
  updated every second.
- Spinner format: `X seconds elapsed total. Y since last event.`
- On terminal status (CREATE_COMPLETE, UPDATE_COMPLETE, DELETE_COMPLETE, any FAILED, any
  ROLLBACK variant): exit 0 for success statuses, exit 1 for failure statuses.
- On inactivity timeout: exit 0 (timeout is not an error).
- Event timestamps use NTP-corrected time when available; falls back to system clock.

**Logic Flow:**

1. Start spinner (interactive mode only).
2. Poll CloudFormation for new events; emit OdStackEvent for each.
3. On terminal status or inactivity timeout: stop spinner, emit summary.

**Edge Cases:**

- Stack not found at watch start: exit 1.
- Stack already in terminal state when watch starts: emit final status, exit immediately.
- SIGINT during watch: exit 130.

---

### US-01-008: Manage changesets (create and execute)

**As a** Platform Engineer, **I want to** create a changeset for review before applying it,
**so that** I can inspect the exact change set CloudFormation will execute before committing.

#### create-changeset

**Acceptance Criteria:**

- Command: `iidy create-changeset <ARGSFILE> [CHANGESET_NAME] [options]`
- `<ARGSFILE>` (positional, required): path to stack-args.yaml.
- `[CHANGESET_NAME]` (positional, optional): name for the changeset. Auto-generated in
  adjective-noun-hex format if omitted.
- `--stack-name <NAME>`: override stack name from argsfile.
- `--watch` (flag, default: false): tail creation events after submitting the changeset.
- `--watch-inactivity-timeout <SECONDS>` (default: 180): inactivity timeout for `--watch` mode.
- `--description <DESC>`: human-readable description stored on the changeset.
- On CREATE_COMPLETE for the changeset: print the changeset ARN and exit 0.
- On FAILED changeset (e.g., no changes): exit 1 with error message.
- If stack does not exist: the changeset is created as a CREATE changeset type.

#### exec-changeset

**Acceptance Criteria:**

- Command: `iidy exec-changeset <ARGSFILE> <CHANGESET_NAME> [options]`
- `<ARGSFILE>` (positional, required): path to stack-args.yaml.
- `<CHANGESET_NAME>` (positional, required): exact name of the changeset to execute.
- `--stack-name <NAME>`: override stack name from argsfile.
- Before executing: display changeset contents (resources to add/modify/remove) and prompt
  for confirmation unless changeset is for a new stack.
- Emit OdStackDefinition before execution.
- Poll events to completion after execution.
- On success: exit 0. On failure: exit 1.

**Edge Cases (both commands):**

- Changeset in FAILED status before exec: exit 1 with descriptive error.
- Timestamps on changeset details are extracted from the creation time field (not wall clock).

---

### US-01-009: List and query stacks

**As a** Platform Engineer or Reviewer, **I want to** list all stacks in a region with filtering
and column selection, **so that** I can audit environments or find stacks by ownership tag.

**Acceptance Criteria:**

- Command: `iidy list-stacks [options]`
- `--tag-filter <KEY=VALUE>` (repeatable): filter stacks to those where the tag KEY equals VALUE.
  Multiple `--tag-filter` flags are ANDed together.
- `--jmespath-filter <EXPR>`: filter the raw AWS stack list via JMESPath before display.
- `--query <JMESPATH>`: apply a JMESPath expression to the output data after filtering.
- `--tags` (flag): include tag columns in the tabular output.
- `--columns <COLS>`: comma-separated list of column names to include (e.g., `Name,Status,Team`).
- Default output: tabular with columns Name, Status, CreationTime (or equivalent).
- In `json` output mode: emits JSON Lines, one object per stack.
- Exit 0 always (even if the list is empty).

**Edge Cases:**

- `--tag-filter` value without `=`: exit 1 with parse error.
- No stacks match filter: exit 0, empty output.

---

### US-01-010: Get stack template

**As a** Developer, **I want to** download the template of a deployed stack and convert it to
a preferred format, **so that** I can inspect or archive the deployed configuration.

**Acceptance Criteria:**

- Command: `iidy get-stack-template <STACKNAME> [options]`
- `<STACKNAME>` (positional, required): stack name or ID.
- `--format <FMT>` (default: `original`): output format. Values: `json`, `yaml`, `original`.
  `original` returns the template as stored by CloudFormation without re-serialization.
- `--stage <STAGE>` (default: `original`): template stage. Values: `original` (as submitted),
  `processed` (after CloudFormation macro transforms).
- Output is written to stdout.
- Exit 0 on success. Exit 1 if stack not found or API error.
- Invalid `--format` or `--stage` value: exit 1 with "Unknown format/stage: ..." message.

---

### US-01-011: Render a preprocessed template

**As a** Developer, **I want to** run iidy's preprocessing pipeline on a template file and
inspect the output without deploying, **so that** I can debug import resolution, Handlebars
rendering, and tag expansion before committing changes.

**Acceptance Criteria:**

- Command: `iidy render <TEMPLATE> [options]`
- `<TEMPLATE>` (positional, required): path to a template file, or `-` to read from stdin.
- `--outfile <FILE>` (default: `stdout`): output file path. `stdout` writes to stdout.
- `--format <FMT>` (default: `yaml`): output serialization. Values: `yaml`, `json`,
  `yaml-cloudformation` (YAML with CloudFormation-specific key ordering and tag syntax).
- `--query <JMESPATH>` (optional): JMESPath expression to filter the rendered output.
- `--overwrite` (flag, default: false): allow overwriting an existing outfile.
- `--yaml-spec <VER>` (default: `auto`): YAML input parsing mode. Values: `1.1`, `1.2`, `auto`.
  `auto` detects `%YAML` directives and applies CloudFormation heuristics. `1.1` treats `yes`,
  `no`, `on`, `off` as booleans; `1.2` treats them as strings.
- Output to stdout matches Rust oracle byte-for-byte (modulo documented YAML serialization
  divergence in test snapshots; see DIVERGENCES.md).
- If outfile exists and `--overwrite` is absent: exit 1 without writing.

**Edge Cases:**

- stdin input (`-`) combined with `--outfile` is valid.
- Handlebars syntax error in template: exit 1 with position in error message.
- Import resolution failure: exit 1 with the import URI in the error message.

---

### US-01-012: Manage SSM parameters

**As a** Platform Engineer, **I want to** read, write, and audit SSM Parameter Store values
through iidy, **so that** I can manage application secrets and configuration with the same
toolchain I use for CloudFormation.

#### param set

- Command: `iidy param set <PATH> <VALUE> [options]`
- `<PATH>` (positional, required): SSM parameter path (e.g., `/myapp/prod/db-password`).
- `<VALUE>` (positional, required): parameter value string.
- `--type <TYPE>` (default: `SecureString`): SSM type. Values: `String`, `StringList`,
  `SecureString`.
- `--overwrite` (flag, default: false): overwrite an existing parameter.
- `--message <MSG>`: attach change description as an `iidy:message` tag on the parameter.
- `--with-approval` (flag, default: false): store as `<PATH>.pending`; requires `param review`
  before the value takes effect at the real path.
- For `SecureString`: KMS alias lookup follows a hierarchical path search from the parameter
  name upward; falls back to the default `aws/ssm` key if no matching alias found.
- Exit 0 on success. Exit 1 if overwrite needed but `--overwrite` absent.

#### param get

- Command: `iidy param get <PATH> [options]`
- `<PATH>` (positional, required).
- `--no-decrypt` (flag): disable decryption of SecureString. Default: decrypt enabled.
- `--format <FMT>` (default: `simple`): Values: `simple` (value only), `json` (full parameter
  object), `yaml`. The alias `raw` is accepted as equivalent to `simple`. Help text displays
  `raw|json|yaml` but the canonical internal name is `ParamFormatSimple`.
- Output goes directly to stdout (not through the output pipeline).
- Exit 0 on success. Exit 1 if parameter not found.

#### param get-by-path

- Command: `iidy param get-by-path <PATH> [options]`
- `<PATH>` (positional, required): path prefix.
- `--no-decrypt` (flag): disable decryption. Default: decrypt enabled.
- `--format <FMT>` (default: `simple`).
- `--recursive` (flag, default: false): include parameters in nested sub-paths.
- `simple` format: YAML map of path to value.
- Exit 0 on success. Exit 1 if no parameters found under path.

#### param get-history

- Command: `iidy param get-history <PATH> [options]`
- `<PATH>` (positional, required).
- `--no-decrypt` (flag, default: decrypt enabled).
- `--format <FMT>` (default: `simple`).
- `simple` format: YAML document with `Current` (latest, with tags) and `Previous` (all older
  versions) sections. Sorted by LastModifiedDate ascending.

#### param review

- Command: `iidy param review <PATH>`
- `<PATH>` (positional, required): path of the pending parameter (the real path, not `.pending`).
- Shows current and pending values side by side.
- Prompts for confirmation; exit 130 on decline.
- On approval: promotes pending value to real path, deletes `.pending` parameter, copies tags.
- Exit 1 if no pending change exists.

**Edge Cases (all param commands):**

- `--format` flag is independent of global `--output-mode`; param commands write directly to
  stdout, not through the output pipeline.
- Hierarchical KMS key lookup for `SecureString` type only.

---

### US-01-013: Template approval workflow

**As a** Reviewer, **I want to** gate production deployments on explicit template review,
**so that** no unapproved CloudFormation changes reach production infrastructure.

#### template-approval request

- Command: `iidy template-approval request <ARGSFILE> [options]`
- `<ARGSFILE>` (positional, required): path to stack-args.yaml. Must include
  `ApprovedTemplateLocation` pointing to an S3 prefix.
- `--no-lint-template` (flag, default: lint enabled): skip pre-submission linting.
- Preprocesses the full template, computes SHA256 hash, uploads to `{prefix}/{hash}.pending`.
- If a matching approved object already exists: reports already-approved, exits 0 without
  uploading.
- Exit 0 on successful submission. Exit 1 on linting failure or S3 error.

#### template-approval review

- Command: `iidy template-approval review <URL> [options]`
- `<URL>` (positional, required): S3 URL of the pending approval object.
- `--context <LINES>` (default: 500): lines of diff context to show. Note: the parser default
  is 500; the command-reference doc shows 100. The parser source (500) is authoritative.
- Fetches pending template and most-recently-approved version.
- Shows colored unified diff.
- Prompts for approval; exit 130 on decline.
- On approval: copies pending to approved key, updates `latest` reference, deletes `.pending`.
- Uploads use `bucket-owner-full-control` ACL for cross-account compatibility.

**Security Model:**

- Enforcement is IAM-based, not application-based. The CloudFormation service role in production
  restricts mutation operations to templates sourced from the approved S3 location.
- iidy does not enforce the security boundary; it makes the workflow ergonomic.

---

### US-01-014: Utility commands

**As a** Developer, **I want to** use iidy utility commands for scaffolding, migration, demos,
shell completion, and error lookup, **so that** I have a self-contained toolchain.

#### demo

- Command: `iidy demo <DEMOSCRIPT> [options]`
- `<DEMOSCRIPT>` (positional, required): path to a demo script file.
- `--timescaling <FACTOR>` (default: `1.0`): multiplier for demo playback timing.
- `--mask-secrets` (flag): redact AWS account numbers and ARNs from command output during demo.

#### convert-stack-to-iidy

- Command: `iidy convert-stack-to-iidy <STACKNAME> <OUTPUT_DIR> [options]`
- `<STACKNAME>` (positional, required): name or ID of an existing CFN stack.
- `<OUTPUT_DIR>` (positional, required): directory to write generated files.
- `--move-params-to-ssm` (flag): write each parameter to SSM at
  `/{environment}/{project}/{key}` as SecureString; reference via `!$ ssmParams.{key}` in
  generated stack-args.yaml. Requires `--project` or a `project` tag on the stack.
- `--no-sortkeys` (flag): do not sort YAML keys in generated files. Default: keys sorted.
- `--project <NAME>`: project name for SSM path prefix.

#### init-stack-args

- Command: `iidy init-stack-args [options]`
- `--force` (flag): overwrite all existing files.
- `--force-stack-args` (flag): overwrite `stack-args.yaml` only.
- `--force-cfn-template` (flag): overwrite `cfn-template.yaml` only.
- Creates `stack-args.yaml` and `cfn-template.yaml` in the current directory (no `--dir` flag;
  see DIVERGENCES note: the command-reference doc mentions `--dir` but the parser does not
  implement it).
- Exit 1 if a file exists and no relevant force flag is set.

#### completion

- Command: `iidy completion [SHELL]`
- `[SHELL]` (positional, optional): `bash`, `zsh`, or `fish`. If omitted:
  auto-detects from `$SHELL` env var (falls back to `bash` for unknown shells).
- Prints the completion script to stdout.
- Only `bash`, `zsh`, and `fish` are accepted as shell names. Any other value (including
  `powershell`) produces a parse error: `"Unknown shell: <value>. Expected: bash|zsh|fish"`.
- The `ShellType` ADT has exactly three variants: `ShellBash | ShellZsh | ShellFish`.
- Auto-detection from `$SHELL` uses `detectShellType` which matches `"zsh"` and `"fish"`
  literally, falling back to `ShellBash` for all other values.

#### explain

- Command: `iidy explain [CODE...]`
- `[CODE...]` (variadic positional): one or more error codes to explain.
- Accepted formats: `ERR_2001` (standard), `err_2001` (case-insensitive), `2001`
  (auto-prefixed). Rust only accepts `ERR_NNNN`; iidy-hs is more permissive
  (documented divergence in DIVERGENCES.md).
- Prints a human-readable explanation for each code.
- Unknown code: prints an error for that code but continues with remaining codes.

#### get-import

- Command: `iidy get-import <IMPORT> [options]`
- `<IMPORT>` (positional, required): import URI (e.g., `ssm:/path`, `./file.yaml`,
  `env:VAR_NAME`).
- `--format <FMT>` (default: `yaml`): output format.
- `--query <JMESPATH>` (optional): filter the resolved value.
- Resolves the import URI and prints the value without full template preprocessing.

#### estimate-cost

- Command: `iidy estimate-cost <ARGSFILE> [--stack-name <NAME>]`
- Submits to the CloudFormation EstimateTemplateCost API.
- Returns a URL to the AWS Simple Monthly Calculator.
- Accepts the same argsfile and `--stack-name` options as `create-stack`.

#### lint-template

- Command: `iidy lint-template <ARGSFILE>`
- `<ARGSFILE>` (positional, required).
- Exit 0 if valid. Exit 1 on preprocessing or validation error.

#### get-stack-instances (hidden)

- Command: `iidy get-stack-instances <STACKNAME> [--short]`
- Hidden from help output (not shown in top-level or subcommand help).
- Still parseable for backward compatibility.
- `--short` (flag): show only DNS names/IP addresses.
- This command is marked removed in the progDesc but remains parseable.

---

### US-01-015: Machine-readable output mode

**As a** CI Pipeline or automation system, **I want to** receive all iidy output as JSON Lines,
**so that** I can parse deployment results, stack events, and errors programmatically.

**Acceptance Criteria:**

- `--output-mode json` activates the JSON renderer for all OutputData types.
- Each OutputData value is serialized as a single JSON object on its own line (JSON Lines /
  NDJSON format).
- All 26 OutputData types are handled by the JSON renderer (23 emit JSON envelopes, 2 are
  suppressed, 1 outputs raw text). See `06-output-system.md` US-06-002 for details.
- `--output-mode json` is valid for all commands. Commands that write directly to stdout
  (param subcommands) are not affected by output mode.
- In `json` mode, spinners and ANSI color codes are suppressed.
- Error messages are also emitted as JSON objects to stderr.
- The `json` mode output must be stable (same input -> same JSON keys and structure across
  invocations).

**Edge Cases:**

- `--output-mode json` combined with `--color always`: ANSI codes are not embedded in JSON
  values; `--color` has no effect in JSON mode.

---

### US-01-016: Environment-based configuration

**As a** Developer managing multiple environments (dev, staging, prod), **I want to** use a
single `-e <ENV>` flag to select AWS profile, region, and other settings, **so that** I do not
need to pass multiple flags for each environment.

**Acceptance Criteria:**

- `--environment <ENV>` (short `-e`, default `development`) is read from the CLI.
- The environment value is passed to the stack-args.yaml loader, which selects the matching
  block (if the argsfile has per-environment overrides).
- The following environment variables are recognized for AWS credential and region resolution:
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`: static credentials.
  - `AWS_PROFILE`: credential profile.
  - `AWS_REGION`, `AWS_DEFAULT_REGION`: region (checked in priority order; CLI `--region`
    takes precedence over both).
  - `AWS_WEB_IDENTITY_TOKEN_FILE`: web identity token for EKS/IRSA.
  - `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`,
    `AWS_CONTAINER_CREDENTIALS_FULL_URI`: ECS task role.
  - `AWS_ROLE_ARN`, `AWS_ROLE_SESSION_NAME`: role assumption for web identity flow.
- For output/color:
  - `NO_COLOR`: if set (any value), disables color output; takes precedence over `FORCE_COLOR`.
  - `FORCE_COLOR`: if set and `NO_COLOR` is absent, forces color even without a TTY.
  - `COLORTERM`: used by `auto` theme detection.
  - `COLUMNS`: not directly read; terminal width is queried from the terminal device.
  - `IIDY_THEME`: sets the default theme when `--theme auto` is active.
  - `SHELL`: used by `completion` command for auto-detecting the shell.
- Priority for region: CLI `--region` > stack-args.yaml `Region` for the selected environment >
  `AWS_REGION` > `AWS_DEFAULT_REGION`. If region is absent from all sources: exit 1 with error.
- Priority for profile: CLI `--profile` (or `no-profile` sentinel) > stack-args.yaml `Profile`
  > `AWS_PROFILE`.
- Priority for role: CLI `--assume-role-arn` (or `no-role` sentinel) > stack-args.yaml
  `AssumeRoleARN`.

**Stack-Args Loading Pipeline (pseudocode):**

The loading pipeline is a multi-step process that requires a bootstrap AWS environment
for imports before the full stack-args can be loaded:

```pseudocode
loadStackArgsFullPipeline(argsfilePath, environment, operation, cliAws, remoteImports):
  -- PASS 1: Bootstrap AWS for imports
  rawAws = extractRawAwsFromFile(argsfilePath, environment)
    -- Parses YAML without preprocessing
    -- Resolves env maps for Profile/Region/AssumeRoleARN from raw AST
    -- On missing env key: returns Nothing (silent fallthrough)
    -- On parse failure: returns empty settings
  bootstrapAws = mergeAwsSettings(cliAws, rawAws)
  bootstrapEnv = createAwsEnv(bootstrapAws)  -- may be Nothing if no AWS needed

  -- PASS 2: Full loading with preprocessing
  return loadStackArgs(argsfilePath, environment, operation, cliAws, remoteImports, bootstrapEnv)

loadStackArgs(argsfilePath, environment, operation, cliAws, remoteImports, mAwsEnv):
  1. content = readFile(argsfilePath)
  2. ast = parseYaml(content)                     -- raw YAML AST
  3. preprocessed = preprocessYaml11(ast, mAwsEnv) -- resolves $imports, custom tags
  4. jsonVal = toValue(preprocessed)
  5. resolved = resolveEnvMaps(jsonVal, environment)
     -- For Profile, Region, AssumeRoleARN:
     --   If field is Object (env map): lookup environment key (case-sensitive)
     --     Found + String: replace field with string value
     --     Found + non-String: ERROR
     --     Not found: ERROR "environment '<env>' not found in <key> map"
     --   If field is String: pass through unchanged
     --   If field is Null/absent: pass through
  6. withEnvTag = ensureEnvironmentTag(resolved, environment)
     -- If Tags.environment is not set, inject it with environment name
  7. withEnvValues = injectEnvValues(withEnvTag, environment, operation, cliAws)
     -- Injects $envValues = {region, environment, iidy: {command, environment, region, profile?}}
  8. argsfileAws = extractAwsSettings(withEnvValues)  -- Profile, Region, AssumeRoleARN
  9. mergedAws = mergeAwsSettings(cliAws, argsfileAws)
  10. detectionCtx = CredentialDetectionContext {
       cdcCliProfile       = cliAws.profile,
       cdcStackArgsProfile = argsfileAws.profile,
       cdcCliAssumeRoleArn = cliAws.assumeRoleArn,
       cdcStackArgsAssumeRoleArn = argsfileAws.assumeRoleArn
     }
  11. stackArgs = valueToStackArgs(withEnvValues)  -- validates unknown keys, parses fields
  12. return (stackArgs, mergedAws, detectionCtx)
```

**Settings Merge and Sentinel Handling (pseudocode):**

```pseudocode
mergeAwsSettings(cli, argsfile):
  profile      = mergeSentinel("no-profile", cli.profile, argsfile.profile)
  region       = cli.region  ?? argsfile.region
  assumeRoleArn = mergeSentinel("no-role", cli.assumeRoleArn, argsfile.assumeRoleArn)

mergeSentinel(sentinel, cliVal, argsfileVal):
  if cliVal == Just sentinel: return Nothing   -- sentinel CLEARS inherited value
  return cliVal ?? argsfileVal                 -- normal precedence
```

**$envValues Injection (pseudocode):**

```pseudocode
buildEnvValues(env, operation, aws):
  return {
    region: aws.region ?? "",
    environment: env,
    iidy: {
      command: operationName(operation),
      environment: env,
      region: aws.region ?? "",
      profile: aws.profile        -- only present if profile is set
    }
  }
```

**Client Request Token Derivation (pseudocode):**

```pseudocode
generateTokenFromMaybe(maybeToken):
  if Just token: return TokenInfo { value=token, source=UserProvided }
  else: return TokenInfo { value=UUID.v4(), source=AutoGenerated }

deriveTokenForStep(primary, step):
  hash = SHA256(primary.value + step)
  value = primary.value[0..8] + "-" + hexEncode(hash)[0..8]
  return TokenInfo { value, source=Derived(from=primary.value, step) }
```

**Global SSM Configuration (pseudocode):**

After stack-args are loaded but before the main operation runs, global configuration
is applied from SSM Parameter Store:

```pseudocode
applyGlobalConfiguration(awsEnv, stackArgs):
  params = try fetchParametersByPath(awsEnv, "/iidy/")
  if error:
    warn("failed to load global config from SSM: " + error)
    return stackArgs
  for (name, value) in params:
    if name == "/iidy/default-notification-arn":
      stackArgs.notificationArns.append(value)
    if name == "/iidy/disable-template-approval" and value == "true":
      if stackArgs.approvedTemplateLocation is set:
        warn("Disabling template approval based on global ... parameter store configuration")
        stackArgs.approvedTemplateLocation = Nothing
  return stackArgs
```

**Unknown Key Validation (pseudocode):**

```pseudocode
validateNoUnknownKeys(keyMap):
  validKeys = {StackName, Template, ApprovedTemplateLocation, Region, Profile,
               AssumeRoleARN, ServiceRoleARN, RoleARN, Capabilities, Tags,
               Parameters, NotificationARNs, TimeoutInMinutes, OnFailure,
               DisableRollback, EnableTerminationProtection, StackPolicy,
               ResourceTypes, UsePreviousTemplate, UsePreviousParameterValues,
               CommandsBefore, $envValues}
  for key in keyMap:
    if key not in validKeys:
      suggestion = closestByLevenshtein(key, validKeys - {$envValues})
      -- suggest if distance <= min(3, len/2 + 1) and distance > 0
      error("Unknown keys: " + key + " (did you mean " + suggestion + "?)")
```

**Edge Cases:**

- Setting `--profile=no-profile` AND having `AWS_PROFILE` set: `AWS_PROFILE` is used (the
  sentinel suppresses the stack-args.yaml profile, not the env var).
- `--assume-role-arn` performs an STS AssumeRole call at session startup and auto-refreshes
  credentials before expiry for long-running watch operations.
- Environment map resolution has different error behavior in the two passes:
  - Bootstrap pass (`extractRawAwsFromAst`): missing env key returns `Nothing` (silent)
  - Full pass (`resolveEnvMaps`): missing env key returns an error

---

## Testing Requirements

- All 23 visible commands (plus 1 hidden) must be parseable without error when given valid
  arguments.
- Global option defaults are verified: environment defaults to `"development"`, color to `auto`,
  theme to `auto`, output mode to unset (TTY-detected), debug to false, log-full-error to false.
- Command-specific defaults verified: `--events` defaults to 50, `--inactivity-timeout` to 180,
  drift cache to 300 seconds, changeset watch inactivity timeout to 180, `--context` to 500,
  `--outfile` to `"stdout"`, `--format` to `"yaml"`, `--yaml-spec` to `auto`,
  `param set --type` to `"SecureString"`.
- Invalid enum values for `--color`, `--theme`, `--output-mode`, `--format`, `--stage`,
  `--yaml-spec` produce exit 1 with the expected error message.
- Help rendering: `--help` with no subcommand triggers the custom top-level help layout.
- Version output: `--version` / `-V` prints `iidy-hs <version>` and exits 0.
- Exit code 130 on user-cancelled operations (delete-stack decline, param review decline,
  exec-changeset decline, template-approval review decline).
- `--no-diff`, `--no-decrypt`, `--no-sortkeys`, `--no-lint-template` flags are tested to
  confirm the default behavior is enabled and the flag disables it.
- Shell completion for bash, zsh, fish: output is non-empty and syntactically plausible.
- Shell completion for unknown shells (including `powershell`): parse error with expected
  values listed.
- `explain` command: accepts `ERR_NNNN`, `err_NNNN`, and bare `NNNN` formats.
- `--no-remote-imports` flag is tested to confirm it disables HTTP/S3 imports while leaving
  AWS API imports (`cfn:`, `ssm:`, `ssm-path:`) unaffected.
- AWS mock fixtures used for all tests involving AWS API calls. No real AWS calls in the test
  suite.

---

## Cross-References

- `docs/command-reference.md` — user-facing documentation with examples
- `DIVERGENCES.md` — documented behavioral differences from Rust iidy:
  - Help formatting layout
  - YAML snapshot serialization (test artifact only, not CLI output)
  - PowerShell completion: Rust prints a not-supported message; iidy-hs rejects at parse time
  - Error color checks stderr TTY (iidy-hs) vs stdout TTY (Rust)
  - `explain` accepts more input formats than Rust
- `docs/requirements/02-yaml-preprocessing.md` — preprocessing pipeline spec
- `docs/requirements/06-output-system.md` — output mode and renderer spec
- Rust oracle: `~/src/iidy/target/debug/iidy` (read-only reference binary)
