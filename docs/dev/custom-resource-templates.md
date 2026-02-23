# Custom Resource Templates

## Overview

Custom resource templates let users define reusable CloudFormation resource
patterns as YAML files. A single template (e.g. a queue with two alarms) can
be stamped out multiple times, each instance receiving its own parameters and
a unique name prefix to avoid logical ID collisions. The output is standard
CloudFormation YAML with no trace of the abstraction.

## Implementation Files

Four modules under `src/Iidy/Yaml/CustomResources/`:

| Module | LOC | Purpose |
|--------|-----|---------|
| `Params.hs` | 188 | `ParamDef`/`TemplateInfo` types, parameter parsing, validation (type/allowed-values/allowed-pattern/schema), default merging |
| `Expansion.hs` | 168 | `expandCustomResource` orchestrator -- property extraction, override deep-merge, global section promotion, ref rewriting dispatch |
| `RefRewriting.hs` | 155 | Prefixes internal `!Ref`, `!GetAtt`, `!Sub`, `Condition`, `DependsOn` references; leaves globals and AWS pseudo-refs untouched |
| `JsonSchema.hs` | 192 | Minimal Draft 7 JSON Schema validator for the `Schema` parameter constraint |

Two external files also participate:

- `src/Iidy/Yaml/Engine.hs` -- `processImports` detects `$params` in imported
  files and builds `TemplateInfo` entries in `tcCustomTemplateDefs`.
- `src/Iidy/Yaml/Resolution/Resolver.hs` -- `resolveResourcesMapping` matches
  each resource's `Type` against the defs map and calls `expandCustomResource`.

## 5-Phase Pipeline

### Phase 1: Import-phase template detection

During `$imports` processing in `Engine.hs`, each imported file is checked for
a top-level `$params` key. If present, `parseParams` converts it into a
`TemplateInfo` and stores it in `tcCustomTemplateDefs` keyed by import name:

```yaml
$imports:
  MonitoredQueue: monitored-queue-template.yaml   # key = "MonitoredQueue"
```

### Phase 2: Resolution dispatch

When the resolver encounters a top-level mapping, it checks whether
`tcCustomTemplateDefs` is non-empty. If so, it routes through
`resolveMappingWithExpansion` (top-level) or `resolveResourcesMapping`
(inside `Resources:`), both in `Resolver.hs`.

### Phase 3: Type matching

For each resource, `getResourceType` extracts the `Type` field. If that type
name exists in `tcCustomTemplateDefs`, the resource is a custom resource
instance. Regular `AWS::*` types pass through unchanged.

### Phase 4: Expansion

`expandCustomResource` in `Expansion.hs` runs five steps:

1. **Extract** `Properties`, `Overrides`, and `NamePrefix` from the resource.
2. **Merge** provided properties with parameter defaults via `mergeParams`.
3. **Validate** all parameters (type, allowed values, pattern, schema).
4. **Re-parse** the template body with parameter bindings substituted (the
   `reparse` callback handles Handlebars interpolation and `!$` resolution).
5. **Deep-merge** any `Overrides` on top of the resolved template output.

### Phase 5: Global promotion

`extractGlobalSections` pulls out the six promotable sections (`Parameters`,
`Outputs`, `Metadata`, `Mappings`, `Conditions`, `Transform`) and merges them
into the parent template. Keys are prefixed with the resource instance name
unless marked with `$global: true`.

## `$params` System

Template files declare parameters with a top-level `$params` sequence:

```yaml
$params:
  - Name: QueueLabel         # required
    Type: String             # optional: String, Number, Object, AWS::*, List<*>
  - Name: AlarmPeriod
    Type: Number
    Default: 60              # used when consumer omits the property
  - Name: Endpoint
    AllowedValues: [us, eu]  # enum constraint
    AllowedPattern: "^[a-z]+$"  # regex constraint (strings only)
  - Name: DbConfig
    Schema:                  # JSON Schema Draft 7 constraint
      type: object
      required: [host, port]
  - Name: Environment
    $global: true            # value comes from parent scope, not Properties
```

Validation skips CloudFormation intrinsic function values (`!Ref`, `Fn::Sub`,
etc.) since their concrete values are unknown at preprocessing time. The
`isCfnRef` check in `Params.hs` recognizes both `Fn::` and `!` tag forms.

## Reference Rewriting

Each template instance gets unique logical IDs by prefixing internal names
with the instance name (e.g. `Queue` becomes `OrderEventsQueue`).
`rewriteRefs` in `RefRewriting.hs` recursively walks the OValue tree:

| Form | Before | After |
|------|--------|-------|
| `!Ref` / `Ref` | `!Ref Queue` | `!Ref OrderEventsQueue` |
| `!GetAtt` / `Fn::GetAtt` | `!GetAtt Queue.Arn` | `!GetAtt OrderEventsQueue.Arn` |
| `!Sub` / `Fn::Sub` | `${Queue.QueueName}` | `${OrderEventsQueue.QueueName}` |
| `Condition` | `Condition: IsEnabled` | `Condition: OrderEventsIsEnabled` |
| `DependsOn` | `DependsOn: Queue` | `DependsOn: OrderEventsQueue` |

References are **not** rewritten when they match:

- **AWS pseudo-references** (`AWS::AccountId`, `AWS::Region`, etc.) --
  hardcoded in `awsPseudoRefs`.
- **Global refs** -- resources/parameters marked `$global: true`, collected
  by `collectGlobalRefs`.
- **Parent resource names** -- non-custom resources defined alongside custom
  instances (e.g. `DeadLetterQueue`), passed as `additionalGlobals`.
- **`!Sub` variable map keys** -- names in the `[template, {vars}]` form are
  added to globals so they are not prefixed in the template string.
- **Literal `!` prefix** -- `${!Literal}` in `Fn::Sub` is a CloudFormation
  escape and is never rewritten.

## OValue Threading

The entire pipeline operates on `OValue` (`src/Iidy/Yaml/OValue.hs`) rather
than aeson's `Value`. `OObject` stores pairs as `[(Text, OValue)]` (ordered
association list) while aeson's `Object` uses `KeyMap` with no guaranteed
order. Converting to `Value` and back would scramble key order, breaking
snapshot tests. Every function (`extractProperties`, `deepMerge`,
`rewriteObject`, `prefixAndRewriteSection`) preserves pair-list structure.
Conversion to `Value` happens only at boundaries: `validateParamSchema` for
schema validation, and the YAML emitter at the end of the pipeline.

## JSON Schema Validation

`JsonSchema.hs` is a 192-line Draft 7 validator covering: `type`, `enum`,
`required`, `properties`, `additionalProperties`, `items`, `pattern`,
`minimum`, `maximum`, `minItems`, `maxItems`, `minLength`, `maxLength`.
Boolean schemas are supported. Validation is recursive for nested objects.
Invoked by `validateParamSchema` in `Params.hs` when a `ParamDef` has a
`Schema` field.

## Testing

**Fixture tests** (`test-fixtures/example-templates/custom-resource-templates/`):
9 input templates with 5 expected outputs. Preprocessed input is compared
against expected YAML. Covers multi-instance expansion, `$global` promotion,
overrides, ref rewriting, and mixing custom + native AWS resources.

**Unit tests** (`test/Main.hs`, `jsonSchemaTests`): 14 tests for the JSON
Schema validator covering type checks, required fields, array items, numeric
bounds, string patterns, length constraints, and boolean schemas.
