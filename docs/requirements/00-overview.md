# PRD: Product Overview

## Overview

iidy ("Is it done yet?" — pronounced "eye-dee") is a CloudFormation preprocessor
and deployer. It wraps the AWS CloudFormation API with a YAML preprocessing
pipeline, structured watch loops for stack events, and change visibility tooling
(diffs, changesets, drift detection). iidy-hs is a feature-complete Haskell port
of the Rust original, with byte-for-byte identical output for all observable
behavior. Any divergence from the Rust binary is documented in `DIVERGENCES.md`.

The Rust binary (`~/src/iidy/target/debug/iidy`) is the behavioral oracle. The
Haskell port must produce identical stdout/stderr content, exit codes, error
messages, and ANSI formatting for all inputs.

## Personas

### Developer
Deploys CloudFormation stacks, writes templates, uses YAML preprocessing for
variable substitution and imports. Primary user of `create-stack`, `update-stack`,
`create-or-update`, `describe-stack`, `watch-stack`, `render`. Expects fast
feedback, readable output, and safe defaults (diff preview, confirmation prompts).

### Platform Engineer
Authors custom resource templates (`$params`, `$defs`, ref rewriting), manages
template approval workflows, configures SSM parameters across environments.
Primary user of `template-approval`, `param` subcommands, `convert-stack-to-iidy`.
Needs reproducible, auditable deployment artifacts.

### CI Pipeline
Automated non-interactive execution. Uses `--output-mode json` for
machine-parseable output, `--yes` to skip confirmation prompts, exit codes for
pass/fail decisions. Must never hang on interactive prompts. Exit code 0 = success,
1 = error, 130 = cancelled.

### Reviewer
Reviews template approvals and parameter changes. Uses `template-approval review`
and `param review`. Needs clear diff presentation and approve/reject workflow.

## Design Principles

### 1. Preprocessing First
All stack-args files pass through a two-phase YAML preprocessing engine before
reaching CloudFormation. Phase 1 resolves `$imports` and `$defs`. Phase 2 resolves
custom tags (15 tag types) and Handlebars interpolation. Templates can also be
preprocessed via the `render:` path prefix on the `Template` field.

See: `02-yaml-preprocessing.md`, `03-import-system.md`

### 2. Real-Time Feedback
Stack operations stream CloudFormation events with 2-second poll intervals.
Spinner display shows elapsed time ("X seconds elapsed total. Y since last event.").
Inactivity timeouts prevent indefinite waiting. Event durations are calculated and
displayed (minimum 1 second).

See: `05-cfn-operations.md`, `06-output-system.md`

### 3. Multiple Output Modes
Three output modes serve different consumers:
- **interactive** (default in TTY): Color-coded, spinners, confirmation prompts,
  themed output (light/dark/high-contrast)
- **plain**: No ANSI codes, suitable for CI logs and piping
- **json**: Machine-parseable newline-delimited JSON, one object per event

Auto-detection: checks if stdout is a TTY. Respects `NO_COLOR` > `FORCE_COLOR` >
TTY check. The `--color` flag overrides with `auto|always|never`.

See: `06-output-system.md`, `12-cross-cutting.md`

### 4. Safe Deployments
- Changeset-based updates with manual approval (`update-stack --changeset`)
- Diff preview before updates (enabled by default, `--no-diff` to skip)
- Confirmation prompts for destructive operations (`delete-stack`)
- Template approval workflow for production deployments (S3-backed)
- Drift detection to identify infrastructure divergence

See: `05-cfn-operations.md`, `10-template-approval.md`

### 5. Deterministic Operations
- Idempotency tokens on all CloudFormation mutations (auto-generated UUIDs or
  user-provided via `--client-request-token`)
- Multi-step operations derive sub-tokens deterministically via SHA256
- Client request token displayed in Command Metadata for traceability

See: `05-cfn-operations.md`

### 6. Environment-Based Configuration
A single `stack-args.yaml` targets multiple environments via maps:
```yaml
Region:
  dev: us-east-1
  prod: us-west-2
Profile:
  dev: dev-account
  prod: prod-account
```
The `-e development|staging|production` flag selects the active environment.
`{{ environment }}` is available in Handlebars interpolation.

See: `01-cli-interface.md`, `02-yaml-preprocessing.md`

### 7. Rich Error Context
- 50+ error codes with structured display (ERR_0001 through ERR_9999)
- Position tracking in YAML errors (line:column with caret indicators)
- AWS console URL suggestions on stack operation errors
- Stack-absent errors include STS caller identity context
- `explain` command provides detailed explanations for any error code

See: `07-error-handling.md`

## Exit Codes

| Code | Meaning                    | When Used                                                   |
|------|----------------------------|-------------------------------------------------------------|
| 0    | Success                    | Operation completed successfully                            |
| 1    | Error                      | Validation failure, AWS error, IO error, unhandled exception|
| 130  | Cancelled                  | User declined confirmation prompt, or SIGINT (Ctrl-C)       |

### Exit Code Details

**Exit 0**: All happy-path completions. Also returned when `delete-stack` target
is already absent (unless `--fail-if-absent` is set).

**Exit 1**: Any error condition — file not found, YAML parse error, CloudFormation
API error, validation failure, template lint failure, missing AWS credentials,
missing region, etc. The specific error code (ERR_XXXX) is displayed in the error
message.

**Exit 130**: Two sources:
- **SIGINT**: Ctrl-C triggers a clean process exit with code 130. This matches the
  Unix convention (128 + signal number, SIGINT = 2).
- **User decline**: When the user responds "No" to a confirmation prompt
  (`delete-stack`, `update-stack` diff preview, changeset execution). Treated as
  a clean exit, not an error.

## Technical Context

**Custom implementations required**: JMESPath evaluation, Handlebars template
rendering, JSON Schema Draft 7 validation, and SNTP time synchronization must
be implemented directly, as no standard off-the-shelf libraries provide the exact
feature subset required by the Rust oracle.

**Key insertion order**: Object key insertion order must be preserved throughout
the entire preprocessing pipeline. Standard JSON/YAML object types that use
unordered maps are insufficient; the internal value representation must maintain
declaration order to produce deterministic output.

**Known Divergences**: See `DIVERGENCES.md`. Key differences: CLI help formatting
layout, error color checks stderr TTY (improvement over Rust), `explain` command
accepts more input formats, PowerShell completion not supported.

## Testing Requirements

- **Unit tests**: Pure logic for YAML preprocessing, handlebars, JMESPath, error
  formatting, event duration calculation.
- **Mock requirements**: All AWS API calls must be testable via fixtures. No real
  AWS calls in the test suite.
- **Snapshot tests**: Render output and error output snapshots compared against
  Rust oracle output to verify byte-for-byte behavioral equivalence.
- **Property tests**: YAML 1.1/1.2 boolean detection, handlebars escaping,
  idempotency token generation.

## Cross-References

- `01-cli-interface.md` — All 22 commands, global options, environment variables
- `02-yaml-preprocessing.md` — YAML preprocessing pipeline, tags, Handlebars
- `03-import-system.md` — Import types, resolution, security model
- `04-custom-resources.md` — Custom resource templates, expansion, schema
- `05-cfn-operations.md` — CloudFormation stack lifecycle, changesets, polling
- `06-output-system.md` — Output modes, renderers, themes, spinners
- `07-error-handling.md` — Error codes, enhanced display, position tracking
- `08-aws-integration.md` — AWS auth chain, credentials, STS, region
- `09-ssm-params.md` — SSM Parameter Store operations
- `10-template-approval.md` — S3-based template approval workflow
- `11-utilities.md` — Utility commands (render, explain, demo, etc.)
- `12-cross-cutting.md` — Cross-cutting concerns (YAML versions, color, NTP)
