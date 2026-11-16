# Getting Started

iidy ("Is it done yet?", [pronounced "eye-dee"](https://www.youtube.com/watch?v=8mq4UT4VnbE&t=50s))
gives you fast, readable feedback on CloudFormation deployments so you never
have to wonder whether things are working or stare at a wall of red text when
they aren't.

## Prerequisites

- **GHCUp**: install via [GHCup](https://www.haskell.org/ghcup/)
- **AWS credentials**: configured via `~/.aws/credentials`, environment variables, or IAM role
- **A CloudFormation template**: any valid YAML or JSON template

## Installation

Build from source with cabal:

```
git clone https://github.com/unbounce/iidy-hs
cd iidy-hs
cabal install
```

Verify the installation:

```
iidy --version
```

## Your First Deployment

This walkthrough deploys a minimal S3 bucket, inspects it, updates it, and
deletes it. No special template syntax -- just a stock CloudFormation template.

### 1. Create a CloudFormation template

Save this as `cfn-template.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: A simple S3 bucket managed by iidy

Parameters:
  BucketSuffix:
    Type: String

Resources:
  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${AWS::StackName}-${BucketSuffix}"

Outputs:
  BucketName:
    Value: !Ref Bucket
  BucketArn:
    Value: !GetAtt Bucket.Arn
```

### 2. Create stack-args.yaml

This file tells iidy what to deploy and how:

```yaml
StackName: iidy-getting-started
Template: ./cfn-template.yaml
Region: us-east-1

Parameters:
  BucketSuffix: demo-assets

Tags:
  Team: platform
  Purpose: getting-started
```

That is the entire configuration. `stack-args.yaml` replaces CLI flags,
parameter files, and wrapper scripts -- everything iidy needs to call the
CloudFormation API is in one readable file. Every field is explained in the
[stack-args.yaml reference](#stack-argsyaml-reference) below.

### 3. Deploy the stack

```
iidy create-stack stack-args.yaml
```

iidy submits the template and parameters to CloudFormation, then streams
events in real time until the operation completes or fails. Output is
color-coded in the terminal; here is what it looks like (abbreviated):

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
 Name:                 iidy-getting-started
 Status:               CREATE_IN_PROGRESS
 Capabilities:         None
 Service Role:         None
 Region:               us-east-1
 Tags:                 Team=platform, Purpose=getting-started
 Parameters:           BucketSuffix=demo-assets
 DisableRollback:      false
 TerminationProtection: false
 Creation Time:        Wed Jan 14 2026 11:14:15
 NotificationARNs:     None
 ARN:                  arn:aws:cloudformation:us-east-1:123456789012:stack/iidy-getting-started/abcd1234
 Console URL:          https://us-east-1.console.aws.amazon.com/cloudformation/home?...

Live Stack Events (2s poll):
 Wed Jan 14 2026 11:14:15 CREATE_IN_PROGRESS  AWS::S3::Bucket              Bucket
 Wed Jan 14 2026 11:14:23 CREATE_COMPLETE     AWS::S3::Bucket              Bucket (8s)
 Wed Jan 14 2026 11:14:25 CREATE_COMPLETE     AWS::CloudFormation::Stack   iidy-getting-started (10s)

Stack Resources:
 Bucket               AWS::S3::Bucket                iidy-getting-started-demo-assets

Stack Outputs:
 BucketName           iidy-getting-started-demo-assets
 BucketArn            arn:aws:s3:::iidy-getting-started-demo-assets

Current Stack Status: CREATE_COMPLETE

SUCCESS: (10s)
```

The first thing you see is what was sent to the API -- stack name, region,
parameters, tags -- so you can verify at a glance that the right values were
used. Then events stream in real time as CloudFormation creates resources.

### 4. Inspect the stack

```
iidy describe-stack iidy-getting-started
```

Shows the stack status, parameters, outputs, resources, and recent events
(abbreviated):

```
Stack Details:
 Name:                 iidy-getting-started
 Status:               CREATE_COMPLETE
 Capabilities:         None
 Service Role:         None
 Region:               us-east-1
 Tags:                 Team=platform, Purpose=getting-started
 Parameters:           BucketSuffix=demo-assets
 DisableRollback:      false
 TerminationProtection: false
 Creation Time:        Wed Jan 14 2026 11:14:15
 NotificationARNs:     None
 ARN:                  arn:aws:cloudformation:us-east-1:123456789012:stack/iidy-getting-started/abcd1234
 Console URL:          https://us-east-1.console.aws.amazon.com/cloudformation/home?...

Previous Stack Events (max 50):
 Wed Jan 14 2026 11:14:25 CREATE_COMPLETE     AWS::CloudFormation::Stack   iidy-getting-started (10s)
 Wed Jan 14 2026 11:14:23 CREATE_COMPLETE     AWS::S3::Bucket              Bucket (8s)
 Wed Jan 14 2026 11:14:15 CREATE_IN_PROGRESS  AWS::S3::Bucket              Bucket

Stack Resources:
 Bucket               AWS::S3::Bucket                iidy-getting-started-demo-assets

Stack Outputs:
 BucketName           iidy-getting-started-demo-assets
 BucketArn            arn:aws:s3:::iidy-getting-started-demo-assets

Current Stack Status: CREATE_COMPLETE
```

### 5. Update the stack

Change `BucketSuffix` in `stack-args.yaml` to `demo-assets-v2`, then:

```
iidy update-stack stack-args.yaml
```

iidy submits the update and watches the operation to completion, showing live
events as resources are modified.

For production updates where you want to review changes before committing, use
`--changeset` to route through a CloudFormation changeset. iidy creates the
changeset, shows exactly what will be added, modified, or replaced, then
prompts for confirmation:

```
iidy update-stack stack-args.yaml --changeset
```

```
? Do you want to execute this changeset now? (y/N)
```

Answer `y` to proceed or `n` to cancel (exit code 130). Use `--yes` to skip
the prompt in CI pipelines.

### 6. List stacks

```
iidy list-stacks
```

Shows all stacks in the current region:

```
Creation/Update Time,    Status,          Name
Wed Jan 14 2026 11:15:30 CREATE_COMPLETE  iidy-getting-started
Fri Jan 09 2026 09:22:00 UPDATE_COMPLETE  vpc-core
Sat Jan 03 2026 14:05:12 CREATE_COMPLETE  monitoring-stack
```

Filter by tags to find stacks owned by a particular team:

```
iidy list-stacks --tag-filter Team=platform
```

### 7. Delete the stack

```
iidy delete-stack iidy-getting-started
```

iidy prompts for confirmation, then deletes the stack and watches until
deletion completes:

```
? Are you sure you want to DELETE the stack iidy-getting-started? (y/N) y

Live Stack Events (2s poll):
 Wed Jan 14 2026 11:20:00 DELETE_IN_PROGRESS  AWS::S3::Bucket              Bucket
 Wed Jan 14 2026 11:20:30 DELETE_COMPLETE     AWS::S3::Bucket              Bucket (30s)
 Wed Jan 14 2026 11:20:35 DELETE_COMPLETE     AWS::CloudFormation::Stack   iidy-getting-started (35s)

SUCCESS: (35s)
```

---

## Environment-Based Configuration

A single `stack-args.yaml` can target multiple environments. Fields like
`Region`, `Profile`, `Parameters`, and `AssumeRoleARN` accept environment maps
-- a mapping of environment names to values:

```yaml
StackName: my-app-{{ environment }}
Template: ./cfn-template.yaml

Region:
  development: us-east-1
  staging: us-west-2
  production: us-east-1

Profile:
  development: dev-profile
  staging: staging-profile
  production: prod-profile

Parameters:
  InstanceType:
    development: t3.micro
    staging: t3.small
    production: m5.large
```

Deploy to different environments with the `-e` flag:

```
iidy -e development create-stack stack-args.yaml
iidy -e staging create-stack stack-args.yaml
iidy -e production create-stack stack-args.yaml
```

The environment name is also available as `{{ environment }}` in string values,
which is how the `StackName` above gets the environment suffix.

---

## Output Modes

iidy has three output modes:

- **interactive** (default in terminals): Color-coded output with themes,
  spinners for in-progress operations, and confirmation prompts.
- **plain**: No ANSI codes, suitable for CI logs.
- **json**: Machine-parseable newline-delimited JSON, one object per event.

iidy detects whether it is connected to a TTY. In interactive mode it uses
color and confirmation prompts; in a CI pipeline it automatically adjusts.
Use `--yes` to skip confirmation prompts in scripts, and `--color never` to
force ANSI codes off.

```
iidy --output-mode plain create-stack stack-args.yaml
iidy --output-mode json describe-stack my-stack
iidy update-stack stack-args.yaml --changeset --yes
```

---

## Importing Values into stack-args.yaml

`stack-args.yaml` is always preprocessed by iidy, even without any special
template syntax. This means you can import values from external sources and
use them in your parameters and tags.

### Pulling from shared files

```yaml
$imports:
  shared: ./shared-config.yaml

StackName: my-app
Template: ./cfn-template.yaml
Region: us-east-1
Parameters:
  DatabaseHost: !$ shared.database_host
Tags:
  Team: !$ shared.team
  CostCenter: !$ shared.cost_center
```

where `shared-config.yaml` contains:

```yaml
team: platform
cost_center: CC-1234
database_host: db.internal.example.com
```

### Pulling from SSM Parameter Store

```yaml
$imports:
  clusterSize: ssm:/myapp/config/cluster-size
  domainName: ssm:/myapp/config/domain-name

StackName: my-app
Template: ./cfn-template.yaml
Parameters:
  ClusterSize: !$ clusterSize
  DomainName: !$ domainName
```

### Pulling from other CloudFormation stacks

```yaml
$imports:
  vpc: cfn:vpc-stack.VpcId
  subnet: cfn:vpc-stack.PrivateSubnetA

StackName: my-app
Template: ./cfn-template.yaml
Parameters:
  VpcId: !$ vpc
  SubnetId: !$ subnet
```

### Defining local variables

Use `$defs` to define reusable values within the file:

```yaml
$defs:
  app: my-app
  env: staging

StackName: "{{ app }}-{{ env }}"
Template: ./cfn-template.yaml
Region: us-east-1
Tags:
  Application: !$ app
  Environment: !$ env
```

Use `iidy render stack-args.yaml` to preview the resolved output. This shows
the final YAML after all imports and variables are substituted.

See [import-types.md](import-types.md) for the full list of import sources
(file, env, git, s3, http/https, ssm, cfn, random, filehash).

---

## Preprocessing CloudFormation Templates

Everything above works with plain CloudFormation templates. When your templates
themselves need abstraction -- reducing repetitive resource definitions,
conditionally including sections, or generating resources from data -- add the
`render:` prefix to enable iidy preprocessing on the template:

```yaml
Template: render:./cfn-template.yaml    # preprocessed by iidy first
Template: ./cfn-template.yaml           # sent to CloudFormation as-is
```

With `render:`, the template file can use the same `$imports`, `$defs`, and
preprocessing tags available in stack-args.yaml.

Preview any template's preprocessed output without deploying:

```
iidy render cfn-template.yaml
```

See [yaml-preprocessing.md](yaml-preprocessing.md) for the full preprocessing
reference.

---

## stack-args.yaml Reference

All fields are optional except `StackName` and `Template`.

| Field | Type | Description |
|-------|------|-------------|
| `StackName` | string | CloudFormation stack name (required) |
| `Template` | string | Path to the template file. Prefix with `render:` for iidy preprocessing (required) |
| `Region` | string or env map | AWS region |
| `Profile` | string or env map | AWS CLI profile name |
| `AssumeRoleARN` | string or env map | IAM role to assume before operations |
| `ServiceRoleARN` | string | IAM service role for CloudFormation to use |
| `RoleARN` | string | Fallback for ServiceRoleARN (used if ServiceRoleARN is not set) |
| `Parameters` | mapping | CloudFormation stack parameters (key: value, or env maps) |
| `Tags` | mapping | Stack tags (key: value). An `environment` tag is added automatically |
| `Capabilities` | list | Required capabilities, e.g., `[CAPABILITY_IAM, CAPABILITY_NAMED_IAM]` |
| `NotificationARNs` | list | SNS topic ARNs for stack event notifications |
| `TimeoutInMinutes` | integer | Stack creation timeout |
| `OnFailure` | string | Action on creation failure: `ROLLBACK`, `DELETE`, or `DO_NOTHING` |
| `DisableRollback` | boolean | Disable automatic rollback on failure |
| `EnableTerminationProtection` | boolean | Prevent accidental stack deletion |
| `StackPolicy` | mapping | Stack policy document (inline YAML) |
| `ResourceTypes` | list | Allowed resource types for the template |
| `UsePreviousTemplate` | boolean | Reuse the existing template during update |
| `UsePreviousParameterValues` | list | Parameter keys to carry forward from previous values |
| `ApprovedTemplateLocation` | string | S3 location for the template approval workflow |
| `CommandsBefore` | list | Shell commands to run before the CloudFormation operation |

Fields marked "env map" accept either a string or a mapping of environment
names to strings. The `--environment` flag selects which value to use.

---

## Next Steps

- [command-reference.md](command-reference.md) -- all commands and options
- [yaml-preprocessing.md](yaml-preprocessing.md) -- the preprocessing language
  for variables, conditionals, and collection transforms
- [import-types.md](import-types.md) -- import source types for `$imports`
