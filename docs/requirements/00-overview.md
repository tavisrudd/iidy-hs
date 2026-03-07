# PRD: Product Overview

## Overview

iidy ("Is it done yet?" — pronounced "eye-dee", from Cab Calloway's "Minnie the
Moocher") is a command-line tool for deploying and managing CloudFormation stacks.
It gives you fast, readable feedback on every operation, a clean workflow for
parameterizing stacks across environments, changeset-based review before updates,
and a multi-team template approval process.

**CloudFormation with Confidence.** The first thing you see after any stack
command is exactly what was sent to the API — stack name, region, parameters,
tags — so a human operator or AI coding agent can instantly verify the right
values were used. Events stream in real time with timing, and errors include line
numbers, suggestions, and console URLs. Whether you are debugging manually or an
AI agent is iterating on your infrastructure, the feedback loop is tight.

**No special template syntax required.** Any valid CloudFormation YAML or JSON
template works as-is. Many teams find iidy valuable without ever touching the
preprocessor. When you do grow into it, the two-phase YAML preprocessing pipeline
(`$imports`, `$defs`, custom tags, Handlebars interpolation) lets you compose
templates from external data sources and reusable parameterized modules. Teams
that become comfortable with the preprocessor also use `iidy render` outside of
CloudFormation to generate Kubernetes manifests, CI configurations, and other
YAML-based artifacts.

## Project Lineage

iidy was born at [Unbounce](https://unbounce.com) out of frustration with
Ansible-wrapped CloudFormation. The old workflow gave almost no feedback for
minutes at a time, then failed with an unreadable wall of red text. Developers
were scared of CloudFormation — not because of CloudFormation itself, but
because the tooling around it made every deployment feel like a dice roll into a
black box. The name captures the question everyone was asking: "Is it done yet?"

| Version    | Repository                                               | Language   |
|------------|----------------------------------------------------------|------------|
| Original   | [unbounce/iidy](https://github.com/unbounce/iidy)       | TypeScript |
| Rewrite    | [tavisrudd/iidy](https://github.com/tavisrudd/iidy)     | Rust       |
| This port  | (this repository)                                        | Haskell    |

The Rust rewrite is feature-complete and serves as the **behavioral oracle** for
this Haskell port. All Rust and Haskell code was written by AI (Claude and Codex)
under strict guidance and review by [@tavisrudd](https://github.com/tavisrudd).

**User-facing documentation** (the canonical reference for iidy's behavior):
- [Getting Started](https://github.com/tavisrudd/iidy/blob/main/docs/getting-started.md)
- [Command Reference](https://github.com/tavisrudd/iidy/blob/main/docs/command-reference.md)
- [YAML Preprocessing](https://github.com/tavisrudd/iidy/blob/main/docs/yaml-preprocessing.md)
- [Import Types](https://github.com/tavisrudd/iidy/blob/main/docs/import-types.md)
- [Custom Resource Templates](https://github.com/tavisrudd/iidy/blob/main/docs/custom-resource-templates.md)
- [Security Model](https://github.com/tavisrudd/iidy/blob/main/docs/SECURITY.md)

The Haskell port must produce identical stdout/stderr content, exit codes, error
messages, and ANSI formatting for all inputs. Any divergence is documented in
`DIVERGENCES.md`.

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

### AI Coding Agent
Consumes iidy's structured output to iterate on infrastructure code. Relies on
`--output-mode json` for machine-parseable event streams, precise error messages
with line/column positions and suggestions for automated correction, and command
metadata that shows exactly what was sent to CloudFormation. The tight feedback
loop (command → structured output → next action) makes iidy suitable for
autonomous deployment workflows.

### Reviewer
Reviews template approvals and parameter changes. Uses `template-approval review`
and `param review`. Needs clear diff presentation and approve/reject workflow.

## Key Concepts

**stack-args.yaml** — The primary deployment descriptor for iidy. A YAML mapping
containing `StackName`, `Template`, `Region`, `Profile`, `Parameters`, `Tags`,
`Capabilities`, and other CloudFormation deployment configuration. Passed as the
`<ARGSFILE>` positional argument to all stack-mutating commands. Supports
environment maps (see below) for multi-environment targeting.

**$defs** — A top-level YAML key defining local constants. Entries are resolved
sequentially (let\* semantics); each may reference earlier entries. Removed from
output. See `02-yaml-preprocessing.md`.

**$imports** — A top-level YAML key mapping variable names to import location
strings. Each entry loads external data (files, environment variables, S3 objects,
SSM parameters, CloudFormation outputs, etc.) into the variable scope for use in
Handlebars interpolation and custom tags. Removed from output.
See `02-yaml-preprocessing.md`, `03-import-system.md`.

**render: prefix** — When the `Template` field in a stack-args.yaml is prefixed
with `render:`, the referenced file is preprocessed through the full iidy
pipeline before being used as the CloudFormation template body.

**Custom resource templates** — Reusable parameterized YAML modules declared via
a `$params` section. When imported and instantiated via a matching `Type` in a
consumer's `Resources` section, they are expanded into multiple prefixed
CloudFormation resources with reference rewriting.
See `04-custom-resources.md`.

**Environment map** — A YAML mapping pattern used in stack-args.yaml fields
(`Region`, `Profile`, `AssumeRoleARN`) where keys are deployment environment names
and values are the corresponding settings. The active value is selected by the
`-e` / `--environment` flag. See Design Principle 6 below.

**Deployment environment** — The target deployment stage selected by `-e` /
`--environment` (e.g., `development`, `staging`, `production`). Default:
`development`.

## Design Principles

### 1. Preprocessing Pipeline
All stack-args files pass through a two-phase YAML preprocessing pipeline before
reaching CloudFormation. Phase 1 resolves `$imports` and `$defs` (I/O-bound:
fetches external data). Phase 2 resolves custom tags (15 tag types) and
Handlebars interpolation (pure: no I/O). Templates referenced via the `render:`
prefix also pass through this pipeline.

Preprocessing is opt-in from the user's perspective: a stack-args.yaml with no
`$imports`, `$defs`, or custom tags passes through unchanged. Any valid
CloudFormation template works as-is.

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
- Multi-step operations derive sub-tokens deterministically:
  `SHA256(primary_token + step_name)` formatted as
  `<primary_first_8_chars>-<hash_first_8_hex_chars>`
- Client request token displayed in Command Metadata for traceability

See: `05-cfn-operations.md`, `12-cross-cutting.md` US-12-004

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
unordered maps are insufficient; the internal value representation (`OValue`,
an ordered-map variant) must maintain declaration order to produce deterministic
output. The `OValue` type wraps `[(Text, OValue)]` for mappings, preserving
insertion order through all transformation phases.

**Known Divergences**: See `DIVERGENCES.md` (required reading for understanding
behavioral gaps from the Rust oracle). Key differences: CLI help formatting
layout, error color checks stderr TTY (improvement over Rust), `explain` command
accepts more input formats, PowerShell completion not supported, SSM `--message`
sets description instead of `iidy:message` tag, KMS alias lookup not implemented,
template approval diff uses LCS algorithm (order-sensitive) rather than
set-theoretic diff.

## Formal Specification

A PLT Redex formal semantics under `spec/` validates the preprocessing pipeline's
core evaluation rules. The Redex model covers import resolution, `$defs` sequential
binding, custom tag evaluation, and Handlebars interpolation. It serves as a
machine-checkable complement to this PRD: the Redex rules define the normative
semantics, while the PRD describes the full system behavior including I/O,
AWS integration, and CLI interface.

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

## Ubiquitous Language

This glossary defines the canonical terms used throughout all PRD documents.

| Term                          | Definition |
|-------------------------------|-----------|
| **stack-args.yaml** (argsfile)| Primary deployment descriptor. YAML mapping with `StackName`, `Template`, `Region`, `Profile`, `Parameters`, `Tags`, `Capabilities`, etc. Passed as positional `<ARGSFILE>` argument. |
| **preprocessing pipeline**    | Two-phase YAML transformation engine. Phase 1: `$imports`/`$defs` (I/O). Phase 2: custom tags + Handlebars (pure). |
| **$defs**                     | Top-level key defining local constants with let\* (sequential) semantics. Removed from output. |
| **$imports**                  | Top-level key mapping variable names to import location strings. Loads external data into variable scope. Removed from output. |
| **$params**                   | Top-level key in a custom resource template defining its parameter interface (names, types, defaults, constraints). |
| **$envValues**                | Internally-injected top-level key in stack-args.yaml containing environment metadata (region, profile, operation name, environment name). Not user-authored; filtered from output. |
| **import location (string)**  | Text value of an `$imports` entry: `file:`, `env:`, `s3://`, `ssm:`, `cfn:`, `git:`, `random:`, `http(s)://`, `filehash:`, or `filehash-base64:`. |
| **custom resource template**  | Reusable parameterized YAML module with `$params`. Expanded into prefixed CFN resources with reference rewriting. |
| **variable scope**            | The binding context built from `$defs` + `$imports`. Passed to Phase 2 for interpolation. Shadowed by `!$let`. |
| **deployment environment**    | Target stage selected by `-e` flag: `development` (default), `staging`, `production`. |
| **environment map**           | YAML mapping keyed by deployment environment name in stack-args.yaml fields (`Region`, `Profile`, `AssumeRoleARN`). |
| **render: prefix**            | `Template` field prefix causing the referenced file to pass through the preprocessing pipeline before use as template body. |
| **template body**             | Fully processed CloudFormation template text submitted to AWS (`TemplateBody` API field). |
| **OutputData**                | Sum type of 26 structured output events emitted by commands (e.g., `OdStackDefinition`, `OdNewStackEvents`). |
| **output mode**               | One of `interactive` (TTY, color, spinners), `plain` (no ANSI), or `json` (NDJSON, one object per event). |
| **Rust oracle**               | The Rust iidy binary serving as the behavioral reference for output equivalence. |
| **error code**                | Unique error identifier in format `ERR_NNNN`. Categories: 1xxx (YAML), 2xxx (variable), 3xxx (import), 4xxx (tag), 5xxx (validation), 6xxx (Handlebars), 7xxx (CloudFormation), 8xxx (config), 9xxx (system). |
| **exit code**                 | Process exit status: 0 (success), 1 (error), 130 (user cancellation or SIGINT). |
| **confirmation prompt**       | Interactive prompt before destructive operations. Format: `? <bold-red message> (y/N)`. Default No. Decline exits 130. |
| **AssumeRoleARN**             | Stack-args.yaml field for STS role assumption. CLI override: `--assume-role-arn`. |
| **idempotency token**         | Client request token (UUID v4 or user-supplied) for safe CloudFormation retries. Multi-step ops derive sub-tokens via SHA256. |
| **global section promotion**  | Mechanism merging `Parameters`, `Outputs`, etc. from expanded custom resource templates into the parent document. |
| **reference rewriting**       | Prefixing logical resource names in expanded custom resources to prevent naming conflicts. Applies to `!Ref`, `!GetAtt`, `!Sub`, `Condition`, `DependsOn`. |
| **deep merge**                | Merge strategy for `Overrides` in custom resource expansion. Objects merge recursively; scalars and arrays replace. |
| **import stack**              | Call-stack for cycle detection during nested import resolution. Duplicate location = circular import error. |
| **spinner**                   | Animated braille-character indicator during polling (interactive mode). 12 frames at 100ms. Shows elapsed time + time since last event. |
| **NTP time provider**         | SNTP client querying `pool.ntp.org:123` for reliable timestamps on write operations. Falls back to system clock. |
