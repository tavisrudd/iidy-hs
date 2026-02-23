# Custom Resource Templates

Custom resource templates let you define reusable CloudFormation resource
patterns as importable YAML documents. A single template stamps out multiple
CFN resources (with monitoring, IAM roles, outputs, etc.) from a compact
declaration.

## Quick example

**Template** (`monitored-queue-template.yaml`):
```yaml
$params:
  - Name: QueueLabel
    Type: String
  - Name: AlarmPriority
    Default: "P3"

Parameters:
  Environment:
    Type: String
    $global: true

Resources:
  Queue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub app--${Environment}--{{QueueLabel}}
  QueueDepthAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub ${Queue.QueueName}-depth
      # ...

Outputs:
  QueueUrl:
    Value: !Ref Queue
```

**Consumer** (`my-stack.yaml`):
```yaml
$imports:
  MonitoredQueue: monitored-queue-template.yaml

Parameters:
  Environment:
    Type: String
    AllowedValues: [development, staging, production]

Resources:
  OrderEvents:
    Type: MonitoredQueue
    Properties:
      QueueLabel: OrderEvents
      AlarmPriority: "P2"
```

**Expands to**:
```yaml
Parameters:
  Environment:
    Type: String
    AllowedValues: [development, staging, production]

Resources:
  OrderEventsQueue:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: !Sub app--${Environment}--OrderEvents
  OrderEventsQueueDepthAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub ${OrderEventsQueue.QueueName}-depth

Outputs:
  OrderEventsQueueUrl:
    Value: !Ref OrderEventsQueue
```

## How it works

### Defining a template

Any imported document with a top-level `$params` key is treated as a custom
resource template. The import key becomes the synthetic resource type name.

### `$params`

Each parameter supports:

| Field | Purpose |
|-------|---------|
| `Name` | Required. The parameter name. |
| `Type` | Type validation: `String`, `Number`, `Object`, or AWS types (passthrough). |
| `Default` | Default value if the consumer doesn't provide one. Can be a CFN intrinsic like `!Ref 'AWS::NoValue'`. |
| `AllowedValues` | List of permitted values. |
| `AllowedPattern` | Regex the value must match (strings only). |
| `Schema` | JSON Schema object for structural validation (see below). |
| `$global` | If `true`, this param name is excluded from ref rewriting. |

### Using a template

In the consumer's `Resources` section, set `Type` to the import key and
provide parameter values under `Properties`:

```yaml
Resources:
  OrderEvents:
    Type: MonitoredQueue
    Properties:
      QueueLabel: OrderEvents
```

### Name prefixing

Each resource in the template gets the consumer's logical name prepended.
`Queue` becomes `OrderEventsQueue`, `QueueDepthAlarm` becomes
`OrderEventsQueueDepthAlarm`. Use `NamePrefix` on the consumer entry to
override:

```yaml
  MyQueue:
    Type: MonitoredQueue
    NamePrefix: Custom
    Properties:
      QueueLabel: MyQueue
```

This produces `CustomQueue`, `CustomQueueDepthAlarm`, etc.

### Ref rewriting

`!Ref`, `!GetAtt`, and `!Sub` references inside the expanded template are
automatically rewritten to use the prefixed resource names. `Condition` and
`DependsOn` fields are also rewritten.

References that are NOT rewritten:
- AWS pseudo-references (`AWS::StackName`, `AWS::AccountId`, etc.)
- Names marked `$global` (in params or section entries)

### Global section promotion (`$global`)

Entries in Parameters, Outputs, Mappings, Metadata, and Transform can be
marked with `$global: true`. These entries:
- Keep their original name (not prefixed)
- Are promoted to the top-level document
- Have `$global: true` stripped from the final output

This is how templates declare shared CFN Parameters, promote Outputs, or
share Mappings across multiple template instances.

Non-global entries in these sections are prefixed and promoted as usual.

If the outer template already defines an entry with the same key, the outer
definition is preserved.

### Schema validation

The `Schema` field accepts a JSON Schema object for validating parameter
structure:

```yaml
$params:
  - Name: Tags
    Schema:
      type: array
      items:
        type: object
        required: [Key, Value]
        properties:
          Key:
            type: string
            minLength: 1
          Value:
            type: string
        additionalProperties: false
```

Schema validation is skipped when the provided value contains CFN intrinsic
functions (`!Sub`, `!Ref`, etc.) since those can't be evaluated at
preprocessing time.

### Overrides

When a template doesn't expose something as a `$param` and you need to tweak
it without forking the template, use `Overrides`. It deep-merges into the
template's resolved output:

```yaml
  FifoQueue:
    Type: MonitoredQueue
    Properties:
      QueueLabel: Fifo
    Overrides:
      Resources:
        Queue:
          Properties:
            FifoQueue: true
            ContentBasedDeduplication: true
```

Overrides are resolved in the outer context, so they can reference
`$defs` and `$imports` from the consuming document.

### Mixing regular and custom resources

Regular AWS resources coexist with custom resource types in the same
`Resources` section. Only entries whose `Type` matches an import key are
expanded; everything else passes through unchanged.

## Team workflows

Custom resource templates enable a separation of concerns between infrastructure
experts and application teams.

**Template authors** (platform/SRE teams) encode organizational best practices
into reusable templates: monitoring thresholds, IAM least-privilege patterns,
tagging standards, naming conventions. Param validation (`AllowedValues`,
`AllowedPattern`, `Schema`) enforces guardrails so consumers can't accidentally
deploy non-compliant resources. Teams get production-ready infrastructure
patterns without needing to understand the underlying complexity -- a single
`Type: MonitoredQueue` gives you a queue, a dead-letter alarm, and an age alarm
with sensible defaults.

**Template consumers** (application teams) use templates like building blocks.
They declare what they need (`Type: MonitoredQueue`, `QueueLabel: OrderEvents`)
and get consistent, validated infrastructure. `Overrides` provides an escape
hatch when a template doesn't expose something as a `$param`, without requiring
a fork or a round-trip with the template author.

### Distribution

Templates are imported via `$imports`, which supports several import sources:

- **Mono-repo**: Templates live alongside application code. Relative paths
  (`$imports: { Queue: ../../shared/monitored-queue.yaml }`) keep everything
  versioned together. Changes to templates are reviewed in the same PR as
  the consuming stacks.

- **S3 bucket**: A shared bucket of blessed templates
  (`$imports: { Queue: s3://company-cfn-templates/monitored-queue/v2.yaml }`).
  Template authors publish versioned artifacts; consumers pin to a version.
  Updates are opt-in.

- **HTTP/HTTPS**: Templates hosted on an internal service or CDN. Useful for
  organizations that already have an artifact registry.

The choice depends on how tightly coupled template evolution should be to
consumer deployments. Mono-repo gives atomic updates; S3/HTTP gives independent
versioning.

## Gotchas

- **Name collisions**: If a prefixed resource name collides with a regular
  resource, last-writer-wins. No warning is emitted.

- **Schema skips CFN intrinsics**: Values containing `!Sub`, `!Ref`, etc. are
  silently skipped during Schema validation. Schema only validates plain data.

- **Overrides bypass validation**: Overrides can set any property on any
  resource, including ones that conflict with param-driven values. No
  conflict detection.

- **Conditions can't use `$global`**: A Condition's value is the expression
  itself (`!Equals [...]`), not a mapping. There's no place for `$global: true`.
  Define shared conditions in the outer template instead.

- **Promoted globals don't overwrite**: If the outer template already defines
  a Parameters entry, the promoted version from the template is skipped.

## Examples

See `example-templates/custom-resource-templates/` for working examples:

| Template | Consumer | Demonstrates |
|----------|----------|-------------|
| `monitored-queue-template.yaml` | `queue-consumers.yaml` | Core expansion, ref rewriting, Outputs/Parameters promotion |
| `deploy-role-template.yaml` | `multi-role-stack.yaml` | Outputs with Export, `$global` params |
| `tagged-bucket-template.yaml` | `data-lake.yaml` | Parameters promotion, preserving outer AllowedValues |
| `lambda-worker-template.yaml` | `event-processors.yaml` | Mappings promotion, Schema validation |
| `monitored-queue-template.yaml` | `overrides-demo.yaml` | Overrides deep-merge |
