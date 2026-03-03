# iidy Rust CLI & UI Specification

## 1. CLI Commands

### Top-Level Structure
Built with `clap` (v3+) using `Parser` derive macro. Main CLI struct (`Cli`) combines:
- Global options (`GlobalOpts`)
- AWS-specific options (`AwsOpts`)
- Command subcommands (`Commands`)

### Global Options

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--environment`, `-e` | String | "development" | Environment for AWS Profile/Region |
| `--color` | ColorChoice (Auto\|Always\|Never) | Auto | ANSI color output control |
| `--theme` | Theme (Auto\|Light\|Dark\|HighContrast) | Auto | Color theme |
| `--output-mode` | OutputMode (Plain\|Interactive\|Json) | Auto-detect | Console output mode |
| `--debug` | bool | false | Log debug info to stderr |
| `--log-full-error` | bool | false | Log full error info to stderr |

### AWS Options

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--region` | String (26 AWS regions) | None | AWS region |
| `--profile` | String | None | AWS profile |
| `--assume-role-arn` | String | None | IAM role ARN to assume |
| `--client-request-token` | String (UUID) | Auto-generated | Idempotency token (max 64 ASCII) |

### Commands Enum

```rust
pub enum Commands {
    CreateStack(CreateStackArgs),
    UpdateStack(UpdateStackArgs),
    CreateOrUpdate(UpdateStackArgs),
    EstimateCost(StackFileArgs),
    CreateChangeset(CreateChangeSetArgs),
    ExecChangeset(ExecChangeSetArgs),
    DescribeStack(DescribeArgs),
    WatchStack(WatchArgs),
    DescribeStackDrift(DriftArgs),
    DeleteStack(DeleteArgs),
    GetStackTemplate(GetTemplateArgs),
    GetStackInstances(GetStackInstancesArgs),
    ListStacks(ListArgs),
    Param { command: ParamCommands },
    TemplateApproval { command: ApprovalCommands },
    Render(RenderArgs),
    GetImport(GetImportArgs),
    Demo(DemoArgs),
    LintTemplate(LintTemplateArgs),
    ConvertStackToIidy(ConvertArgs),
    InitStackArgs(InitStackArgs),
    Completion { shell: Option<Shell> },
    Explain { codes: Vec<String> },
}
```

### Stack Operations

**create-stack** `<argsfile>` -- Create a CloudFormation stack
- `--stack-name`: Override stack name

**update-stack** `<argsfile>` -- Update an existing stack
- `--stack-name`, `--lint-template`, `--changeset`, `--yes`, `--diff` (default: true), `--stack-policy-during-update`

**create-or-update** `<argsfile>` -- Create if absent, update if exists (same args as update-stack)

**estimate-cost** `<argsfile>` -- Estimate AWS costs
- `--stack-name`

**delete-stack** `<stackname>` -- Delete a stack (with confirmation)
- `--role-arn`, `--retain-resources` (multiple), `--yes`, `--fail-if-absent`

### Changeset Operations

**create-changeset** `<argsfile>` [changeset_name]
- `--stack-name`, `--watch`, `--watch-inactivity-timeout` (180s), `--description`

**exec-changeset** `<argsfile>` `<changeset_name>`
- `--stack-name`

### Stack Inspection

**describe-stack** `<stackname>` -- Detailed stack info + events
- `--events` (50), `--query` (JMESPath)

**watch-stack** `<stackname>` -- Monitor during operations
- `--inactivity-timeout` (180s)

**describe-stack-drift** `<stackname>` -- Detect resource drift
- `--drift-cache` (300s)

**get-stack-template** `<stackname>` -- Download live template
- `--format` (Original|Json|Yaml), `--stage` (Original|Processed)

**list-stacks** -- List all stacks
- `--tag-filter`, `--jmespath-filter`, `--query`, `--tags`, `--columns`

### Template Operations

**render** `<template>` -- Pre-process YAML template
- `--outfile` (stdout), `--format` (yaml|json|yaml-cloudformation), `--query` (JMESPath), `--overwrite`, `--yaml-spec` (1.1|1.2|auto)

**get-import** `<import>` -- Retrieve $import value
- `--format` (yaml|json), `--query`

**lint-template** `<argsfile>` -- Validate template
- `--use-parameters`

### Parameter Store Operations

**param set** `<path>` `<value>` -- Create/update SSM parameter
- `--message`, `--overwrite`, `--with-approval`, `--type` (String|StringList|SecureString)

**param get** `<path>` -- Retrieve parameter
- `--decrypt` (true), `--format` (simple)

**param get-by-path** `<path>` -- Get multiple by path prefix
- `--decrypt` (true), `--format`, `--recursive`

**param get-history** `<path>` -- Parameter history
- `--decrypt` (true), `--format`

**param review** `<path>` -- Review pending changes

### Template Approval

**template-approval request** `<argsfile>` -- Request approval
- `--lint-template` (true)

**template-approval review** `<url>` -- Review pending
- `--context` (500)

### Utility Commands

**convert-stack-to-iidy** `<stackname>` `<output_dir>` -- Create iidy project from live stack
- `--move-params-to-ssm`, `--sortkeys` (true), `--project`

**init-stack-args** -- Initialize stack-args.yaml
- `--force`, `--force-stack-args`, `--force-cfn-template`

**completion** [shell] -- Generate shell completions (bash|zsh|fish|powershell|elvish)

**explain** `<codes>...` -- Show error explanations (ERR_XXXX)

**demo** `<demoscript>` -- Run demo script
- `--timescaling` (1.0), `--mask-secrets`

## 2. Output Formats

### Output Mode Selection
- **Interactive**: TTY detected. Colorized, spinners, interactive prompts
- **Plain**: Non-TTY (pipes/files). No colors, no spinners, auto-declines prompts
- **JSON**: Structured JSONL (one JSON object per line). Machine-readable

### OutputData Variants
- `CommandMetadata` -- Operation start info (environment, region, IAM principal, version, tokens)
- `StackDefinition` -- Stack properties (name, ARN, status, params, tags, outputs, timestamps)
- `StackEventsDisplay` -- Event stream (timestamps, resources, statuses, reasons)
- `StackContents` -- Complete state (resources, outputs, exports, changesets)
- `StatusUpdate` -- Real-time progress (message, timestamp, level)
- `CommandResult` -- Outcome (success, elapsed, exit code)
- `FinalCommandSummary` -- Summary (result, elapsed time)
- `ErrorInfo` -- Error details (type, message, suggestions)
- `ChangeSetResult` -- Changeset info (name, status, changes list)
- `StackDrift` -- Drift detection (resources, property diffs)
- `ConfirmationPrompt` -- Interactive yes/no
- `StackList`, `StackTemplate`, `CostEstimate`, `ApprovalRequestResult`
- `TemplateDiff`, `TokenInfo`, `InactivityTimeout`, `OperationComplete`

## 3. Terminal UI (Interactive Renderer)

### Layout
- Column 2 starts at 25 characters (labels)
- Min status padding: 17 chars, Max: 60 chars
- Resource type padding: 40 chars
- Blank lines between sections

### Color Scheme (Dark Theme)

| Element | Color |
|---------|-------|
| Timestamps | RGB(212,212,212) xterm 253 |
| Resource IDs | RGB(198,198,198) xterm 252 |
| Section Headings | RGB(238,238,238) xterm 255 |
| Muted Text | RGB(128,128,128) gray |
| Primary | Magenta |
| Success | Green |
| Error | Red |
| Warning | Yellow |
| Info | White |
| Skipped | RGB(88,88,88) xterm 240 |

**Themes**: Dark (default), Light, HighContrast, Auto

**Environment Colors**: Production=Red, Integration=xterm 75, Development=xterm 194

### Spinners

| Style | Animation | Color | Tick |
|-------|-----------|-------|------|
| Dots | ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ | Cyan bold | 100ms |
| Dots12 | Extended dots | Cyan bold | 100ms |
| Line | ⠂⠄⠅⠇⡇⣇⣧⣷⣿ | Yellow | 100ms |
| Arrow | ←↖↑↗→↘↓↙ | Magenta | 200ms |
| Pulse | ⚫⚪ | Green | 200ms |

### CloudFormation Status Display

| Category | Color | Icon |
|----------|-------|------|
| IN_PROGRESS | Yellow | (spinner) |
| COMPLETE | Green | (checkmark) |
| FAILED | Red | (x) |
| SKIPPED | Gray | (skip) |

### Live Event Polling
- 2-second intervals
- Duration calculations
- Async section ordering
- Spinner during waits

## 4. Error Handling

### Error ID System (ERR_XXXX)

| Range | Category |
|-------|----------|
| 1xxx | YAML Syntax & Parsing |
| 2xxx | Variable & Scope |
| 3xxx | Import & Loading |
| 4xxx | Tag Syntax |
| 5xxx | Type & Validation |
| 6xxx | Handlebars |
| 7xxx | CloudFormation |
| 8xxx | Configuration |
| 9xxx | Internal/System |

### Error Display Format

```
  99 | previous line content...
→100 | error line content...
     |      ^^^^^ error description
 101 | next line content...
```

**Error Colors** (respects NO_COLOR):
- Bold Red: Error indicators
- Red: Line numbers of error
- Cyan: File paths
- Blue-Grey: Source code context
- Light Blue: Hints/annotations

## 5. Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error |
| 130 | Cancelled (user declined/CTRL-C) |

## 6. Color Control

| Variable | Behavior |
|----------|----------|
| NO_COLOR | Disables all color (takes precedence) |
| FORCE_COLOR | Forces color even in non-TTY |
| COLORTERM=truecolor\|24bit | Enables 24-bit true color |

Auto-detection: NO_COLOR → FORCE_COLOR → TTY check → COLORTERM → fallback no colors

## 7. Key Implementation Modules

- `cli.rs` (900 LOC): Clap definitions, command parsing
- `main.rs` (306 LOC): Entry point, command routing
- `output/mod.rs`: Output architecture
- `output/renderer.rs`: OutputRenderer trait, OutputMode enum
- `output/renderers/interactive.rs` (2438 LOC): TUI with colors, spinners
- `output/renderers/json.rs`: JSONL output
- `output/data.rs`: OutputData enum, all display types
- `output/manager.rs`: DynamicOutputManager, mode switching
- `output/theme.rs`: Color themes, terminal detection
- `output/color.rs`: Global color context
- `output/status.rs`: CloudFormation status constants
- `output/spinner.rs`: Spinner animations
- `yaml/errors/ids.rs`: Error ID definitions
- `yaml/errors/display.rs`: Error formatting with source context
