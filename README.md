# iidy -- a Haskell port released only 3 days after a Rust one? WTF?

This is a Haskell port of the Rust
[iidy](https://github.com/tavis/iidy) rewrite of the original
TypeScript [iidy-js](https://github.com/unbounce/iidy). The port is
feature-complete and has identical behaviour and output to the Rust
port, which itself is compatible with iidy-js but has much improved
error reporting and other enhancements.

*Why on Earth does a second port exist?* Because Tavis wanted to see
how far he could push Claude in a single day in which he stepped away
from the screen. *Why Haskell?* Because Tavis thought it would be hard
for Claude. He was wrong.

Unlike the Rust port, all code was written by Claude in a [ralph
loop](https://ghuntley.com/loop/) in a single day, with minimal
guidance by [@tavisrudd](https://github.com/tavisrudd).

This intro is the only human generated content in this entire repo.

------

# iidy -- CloudFormation with Confidence

iidy ("Is it done yet?", [pronounced "eye-dee"](https://www.youtube.com/watch?v=8mq4UT4VnbE&t=50s))
is a command-line tool for deploying and managing CloudFormation stacks. It gives you fast, readable feedback on every operation,
a clean workflow for parameterizing stacks across environments, changeset-based
review before updates, and a multi-team template approval process. It also
includes an optional YAML preprocessing language for reducing boilerplate in
complex templates.

[![asciicast](https://asciinema.org/a/8rzW1WyoDxMdVJpvpYf2mHm8E.png)](https://asciinema.org/a/8rzW1WyoDxMdVJpvpYf2mHm8E)

## Deploy a stack in 60 seconds

```yaml
# stack-args.yaml
StackName: my-app
Template: ./cfn-template.yaml
Region: us-east-1
Parameters:
  InstanceType: t3.micro
  Environment: staging
Tags:
  Team: platform
  CostCenter: CC-1234
```

```
iidy create-stack stack-args.yaml
```

No special template syntax is required. Any valid CloudFormation YAML or JSON
template works as-is. iidy submits it to CloudFormation and streams events in
real time (color-coded in the terminal):

```
Command Metadata:
 CFN Operation:        create-stack
 iidy Environment:     development
 Region:               us-east-1
 IAM Service Role:     None
 Current IAM Principal: arn:aws:iam::123456789012:user/deployer
 CLI Arguments:        region=us-east-1, argsfile=stack-args.yaml
 iidy Version:         1.0.0
 Client Req Token:     a1b2c3d4-e5f6-7890-abcd-ef1234567890 (auto-generated)

Stack Details:
 Name:                 my-app
 Status:               CREATE_IN_PROGRESS
 Capabilities:         None
 Service Role:         None
 Region:               us-east-1
 Tags:                 Team=platform, CostCenter=CC-1234
 Parameters:           InstanceType=t3.micro, Environment=staging
 DisableRollback:      false
 TerminationProtection: false
 Creation Time:        Wed Jan 14 2026 11:14:15
 NotificationARNs:     None
 ARN:                  arn:aws:cloudformation:us-east-1:123456789012:stack/my-app/abcd1234
 Console URL:          https://us-east-1.console.aws.amazon.com/cloudformation/home?...

Live Stack Events (2s poll):
 Wed Jan 14 2026 11:14:15 CREATE_IN_PROGRESS  AWS::S3::Bucket              AppBucket
 Wed Jan 14 2026 11:14:22 CREATE_COMPLETE     AWS::S3::Bucket              AppBucket (7s)
 Wed Jan 14 2026 11:14:24 CREATE_COMPLETE     AWS::CloudFormation::Stack   my-app (9s)

Stack Resources:
 AppBucket            AWS::S3::Bucket                my-app-demo-assets

Stack Outputs:
 BucketName           my-app-demo-assets
 BucketArn            arn:aws:s3:::my-app-demo-assets

SUCCESS: (9s)
```

The first thing you see is what was sent to the API -- parameters, tags,
region, IAM principal -- so a human operator or AI coding agent can instantly
verify the right values were used. Then events stream as resources are created.
When something goes wrong, the error is right there in the event stream, not
buried in the AWS console.

## Why iidy

### Readable, fast feedback

The AWS CLI and most CloudFormation frontends give poor feedback during
deployments. iidy shows a color-coded event stream with clear section
structure, spinners for in-progress operations, and confirmation prompts.

When something goes wrong, iidy provides precise, actionable error messages.
CloudFormation operation failures and template validation errors surface
immediately with context. Preprocessing errors include the exact file, line,
and column of the problem, the surrounding YAML context, and examples of how
to correct it -- so whether you are debugging manually or an AI coding agent
is iterating on your infrastructure, the feedback loop is tight:

```
Variable error: 'app_name' not found @ stack-args.yaml:6:15 (errno: ERR_2001)
  -> variable not defined in current scope

   5 |
   6 | stack_name: "{{app_name}}-{{environment}}"
     |               ^^^^^^^^^^^ variable not defined

   available variables: environment, region

   For more info: iidy explain ERR_2001
```

CloudFormation operation failures are equally clear. A failed update shows the
failing resource and the reason inline in the event stream:

```
Live Stack Events (2s poll):
 Wed Jan 14 2026 11:14:15 UPDATE_IN_PROGRESS   AWS::EC2::Instance           AppServer
 Wed Jan 14 2026 11:14:18 UPDATE_FAILED        AWS::EC2::Instance           AppServer
  Parameter validation failed: Invalid value 't3.nonexistent' for InstanceType
 Wed Jan 14 2026 11:14:20 UPDATE_ROLLBACK_IN_PROGRESS  AWS::CloudFormation::Stack   my-app
 ...

FAILURE: (42s)
```

iidy is built for both humans at a terminal and CI pipelines. For interactive
use it provides color themes, TTY detection, and confirmation prompts. For CI
it supports `--output-mode plain` (no ANSI codes), `--output-mode json`
(machine-parseable newline-delimited JSON), and `--yes` to skip confirmation
prompts.

### Simple stack configuration

`stack-args.yaml` puts stack name, template path, parameters, tags, region,
profile, and IAM role in one file. No wrapper scripts, no CloudFormation
parameter files, no CLI flags to remember. The output from every command clearly
shows what was sent to the API, so you can verify at a glance.

A single stack-args file can target multiple environments:

```yaml
StackName: my-app-{{ environment }}
Template: ./cfn-template.yaml

Region:
  development: us-east-1
  staging: us-west-2
  production: us-east-1

Parameters:
  InstanceType:
    development: t3.micro
    staging: t3.small
    production: m5.large
```

```
iidy -e staging create-stack stack-args.yaml
iidy -e production create-stack stack-args.yaml
```

### Changeset workflow

`update-stack` shows a template diff and prompts for confirmation before
submitting. Pass `--changeset` and iidy creates a CloudFormation changeset,
shows exactly what will be added, modified, or replaced, then asks y/n before
executing:

```
iidy update-stack stack-args.yaml --changeset
```

This is the right workflow for production updates: see the full impact before
committing.

### Template approval

For teams that need sign-off before deploying to production, iidy provides a
built-in approval workflow backed by S3 versioning:

```
# Developer iterates in sandbox, then requests approval
iidy template-approval request stack-args.yaml

# Reviewer sees a colored diff and approves or rejects
iidy template-approval review <approval-url>
```

Once a template is approved, subsequent deployments with parameter-only changes
do not require re-approval. This lets dev teams iterate quickly in sandbox
environments and get fast review from whoever gatekeeps production access,
without re-approving unchanged infrastructure.

### YAML preprocessing for growing complexity

Many teams find iidy valuable without ever touching the preprocessor. But as
infrastructure complexity grows, `stack-args.yaml` already supports importing
values from external sources -- files, environment variables, SSM Parameter
Store, S3, other CloudFormation stacks -- to keep parameters and tags
consistent across stacks:

```yaml
$imports:
  shared: ./shared-config.yaml
  dbHost: ssm:/myapp/prod/database-host

StackName: my-app
Template: ./cfn-template.yaml
Region: us-east-1
Parameters:
  DatabaseHost: !$ dbHost
Tags:
  Team: !$ shared.team
  CostCenter: !$ shared.cost_center
```

For templates themselves, adding a `render:` prefix enables iidy's full
preprocessing language -- variables, conditionals, and collection transforms
that generate repetitive template sections. The language operates on YAML data
structures, not strings: it is purely functional (side-effect-free once imports
are loaded) data transformations layered on top of valid YAML. See
[yaml-preprocessing.md](docs/yaml-preprocessing.md) for the full reference.

Teams that become comfortable with the preprocessor also use `iidy render`
outside of CloudFormation to generate Kubernetes manifests, CI configurations,
and other YAML-based artifacts.

## Commands

| Category | Command | Description |
|----------|---------|-------------|
| Deploy | `create-stack` | Create a new stack |
| | `update-stack` | Update an existing stack (diff + confirm) |
| | `create-or-update` | Create or update depending on stack state |
| | `delete-stack` | Delete a stack (with confirmation) |
| Changesets | `create-changeset` | Create a changeset for review |
| | `exec-changeset` | Execute a previously created changeset |
| Monitor | `describe-stack` | Show stack status, parameters, outputs, events |
| | `watch-stack` | Tail events on an in-progress operation |
| | `describe-stack-drift` | Detect configuration drift |
| Info | `list-stacks` | List stacks (with tag filtering) |
| | `get-stack-template` | Download a deployed stack's template |
| | `get-import` | Resolve an import URI |
| Preprocess | `render` | Preview preprocessed YAML output |
| Approval | `template-approval request` | Submit a template for approval |
| | `template-approval review` | Review and approve/reject a pending template |
| Cost | `estimate-cost` | Estimate stack costs |
| SSM | `param set/get/get-by-path` | Manage SSM parameters |
| Utilities | `explain` | Explain error codes |
| | `completion` | Generate shell completions |

## Documentation

- **[Getting Started](docs/getting-started.md)** -- installation, first
  deployment, stack-args.yaml reference
- **[Command Reference](docs/command-reference.md)** -- all commands, options,
  and exit codes
- **[YAML Preprocessing](docs/yaml-preprocessing.md)** -- the preprocessing
  language for imports, variables, conditionals, and collection transforms
- **[Import Types](docs/import-types.md)** -- file, env, git, s3, ssm, cfn,
  and other import sources
- **[Security](docs/SECURITY.md)** -- import system security model for remote
  templates

## Origin

iidy was born at [Unbounce](https://unbounce.com) out of frustration with a
painful CloudFormation workflow. CloudFormation was wrapped in Ansible, which
provided almost no feedback for minutes at a time until it would fail with an
unreadable wall of red text. Developers were scared of CloudFormation -- not
because of CloudFormation itself, but because the tooling around it made every
deployment feel like a dice roll into a black box. The name captures the
question everyone was asking while staring at the terminal: "Is it done yet?"

The pronunciation comes from Cab Calloway's
["Minnie the Moocher"](https://www.youtube.com/watch?v=8mq4UT4VnbE&t=50s) --
say it like the audience call-and-response: "eye-dee."

Development of the original iidy was funded by
[Unbounce](https://unbounce.com).
