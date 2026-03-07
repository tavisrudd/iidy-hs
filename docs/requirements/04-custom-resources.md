# PRD: Custom Resource Templates

## Overview

Custom resource templates are iidy's mechanism for defining reusable CloudFormation
resource patterns as importable YAML documents. A single template declaration in a
consumer stack expands into multiple CFN resources — queues with alarms, Lambda
functions with IAM roles, buckets with policies — from a compact, validated
instantiation.

The feature serves two distinct roles. Template authors (platform and SRE teams)
encode organizational best practices into parameterized, constraint-enforced templates.
Template consumers (application teams) instantiate those templates as opaque building
blocks, providing only the parameters they care about. The preprocessing pipeline
handles naming, reference rewriting, and section promotion transparently.

### Scope

This document covers:

- The `$params` parameter definition system
- Template detection and import binding
- The five-phase expansion pipeline
- Reference rewriting rules
- Global section promotion
- The `Overrides` deep-merge escape hatch
- JSON Schema Draft 7 parameter validation
- Multi-instance expansion from a single template

Out of scope: the `$imports` resolution mechanism itself (covered in PRD-03), CFN
intrinsic function evaluation, and live AWS resource resolution.

---

## Technical Context

### Expansion Pipeline (Five Phases)

1. **Import detection**: Any imported document with a top-level `$params` key is
   classified as a custom resource template. The import key becomes the synthetic
   resource type name.
2. **Instance detection**: In the consumer's `Resources` section, entries whose
   `Type` matches an import key are routed to the expansion pipeline. All others
   pass through unchanged. Circular template expansion (a template referencing
   itself directly or indirectly) is detected via an `activeExpansions` set and
   rejected with: `"Circular template expansion detected: '<typeName>' is already
   being expanded"`.
3. **Parameter extraction and merging**: `Properties` from the resource instance
   are extracted as the provided parameter map. Defaults from `ParamDef` fill in
   any missing keys via `mergeParams`.
4. **Validation**: The merged parameter map is checked against all `ParamDef`
   constraints (type, AllowedValues, AllowedPattern, Schema) via `validateParams`.
   CFN intrinsic values (those containing `!Ref`, `!Sub`, etc.) are exempted from
   structural constraints because they cannot be evaluated at preprocessing time.
5. **Template re-parse and expansion**: The template's raw body is re-parsed with
   the merged parameters as Handlebars bindings. The resolved value tree then has
   `Overrides` deep-merged in, references rewritten with the name prefix, and
   non-Resources sections promoted to the parent document via `extractGlobalSections`.

**Pipeline type declarations** (pseudocode):

```
-- Core types
data ParamDef = ParamDef
    { pdName          :: Text
    , pdDefault       :: Maybe OValue
    , pdType          :: Maybe Text          -- "String" | "Number" | "Object" | "AWS:..." | "List<...>" | "CommaDelimitedList"
    , pdAllowedValues :: Maybe [OValue]
    , pdAllowedPattern:: Maybe Text          -- POSIX regex
    , pdSchema        :: Maybe JSON.Value    -- JSON Schema Draft 7
    , pdIsGlobal      :: Bool
    }

data TemplateInfo = TemplateInfo
    { tiParams   :: [ParamDef]
    , tiRawBody  :: Text                     -- raw YAML source for re-parse
    , tiLocation :: Text                     -- file path for error messages
    }

data ExpansionResult = ExpansionResult
    { erResources      :: [(Text, OValue)]   -- prefixed resource name -> rewritten value
    , erGlobalSections :: Map Text OValue     -- section name -> promoted section object
    }

-- Pipeline entry point
expandCustomResource
    :: Text                                   -- instance name (e.g., "OrderEvents")
    -> OValue                                 -- resource definition (Properties, Overrides, NamePrefix)
    -> TemplateInfo                           -- template with params and raw body
    -> (Map Text OValue -> Text -> Either Text OValue)  -- re-parser (params -> body -> resolved)
    -> Set Text                               -- additional globals (parent resource names)
    -> Either Text ExpansionResult

-- Pipeline steps (in sequence):
--   1. prefix     = extractPrefix name resourceDef        -- NamePrefix or instance name
--   2. properties = extractProperties resourceDef         -- Properties as Map Text OValue
--   3. overrides  = extractOverrides resourceDef          -- Maybe OValue
--   4. merged     = mergeParams templateInfo.params properties
--   5. _          <- validateParams templateInfo.params merged
--   6. resolved   <- reparse merged templateInfo.rawBody
--   7. withOvr    = deepMerge resolved overrides          -- if present
--   8. globals    = collectGlobalRefs withOvr ∪ awsPseudoRefs ∪ additionalGlobals
--   9. resources  = map (prefixKey, rewriteRefs prefix globals) (extractResources withOvr)
--  10. sections   = extractGlobalSections prefix globals withOvr
```

### Key-Order Preservation

All expansion operations preserve YAML key insertion order by using an ordered-map value
type throughout. Reference rewriting, section promotion, deep merge, and extraction all
operate on this ordered type rather than converting to an unordered map until JSON Schema
validation requires it.

### Reference Rewriting Rules

The reference rewriter applies the name prefix to every logical reference inside the
expanded template body. The complete set of rewrite sites:

| Site                     | Behavior                                                   |
|--------------------------|------------------------------------------------------------|
| `!Ref` / `Ref`          | Value string prefixed if not in globals set                |
| `!GetAtt` / `Fn::GetAtt`| Resource portion (before `.`) prefixed                     |
| `!Sub` / `Fn::Sub`      | `${...}` interpolations prefixed; `${!Literal}` left alone |
| `Fn::Sub` with var map  | Template rewritten; variable map keys added to globals set |
| `Condition` field        | String value prefixed if not in globals set                |
| `DependsOn` field        | String or array of strings prefixed                        |

**Rewrite dispatch** (pseudocode):

```
rewriteRefs :: Text -> Set Text -> OValue -> OValue
rewriteRefs prefix globals val = case val of
    OObject kvs
      | single-key "Ref"        -> rewriteRefValue prefix globals refVal
      | single-key "Fn::GetAtt" -> rewriteGetAtt prefix globals attVal
      | single-key "Fn::Sub"    -> rewriteSub prefix globals subVal
      | single-key "!Ref"       -> rewriteRefValue prefix globals refVal
      | single-key "!GetAtt"    -> rewriteGetAtt prefix globals attVal
      | single-key "!Sub"       -> rewriteSub prefix globals subVal
      | otherwise               -> rewriteField for each (key, value):
                                     "Condition" -> prefix string if shouldRewrite
                                     "DependsOn" -> prefix string or each array element
                                     _           -> recurse into value
    OArray items -> map (rewriteRefs prefix globals) items
    scalar       -> scalar

-- GetAtt handles both forms:
rewriteGetAtt prefix globals = \case
    OString "Resource.Attr"  -> prefix Resource portion before "."
    OArray [OString r, rest] -> prefix first element if shouldRewrite
    other                    -> unchanged

-- Sub template string parser:
rewriteSubTemplate prefix globals template =
    scan for "${...}" interpolations:
      "${!literal}" -> leave unchanged (literal escape)
      "${name}"     -> prefix name if shouldRewrite globals name
      malformed "${ without }" -> return entire string unchanged

-- Two-argument Sub:
rewriteSub prefix globals (OArray [OString template, OObject varMap]) =
    extendedGlobals = globals ∪ {keys of varMap}
    rewrite template with extendedGlobals
    rewrite varMap values with original globals

shouldRewrite :: Set Text -> Text -> Bool
shouldRewrite globals name
    | "AWS::" `isPrefixOf` name = False
    | name ∈ globals            = False
    | otherwise                 = True
```

Names that are never rewritten:

- Any name in the `AWS::` namespace (`AWS::AccountId`, `AWS::Region`, etc.)
- Names in the globals set (entries marked `$global: true`)
- The consuming resource's own logical name (passed as additional globals)
- Variable map keys in two-argument `Fn::Sub`
- `${!LiteralText}` inside Sub templates

**Global ref collection**: `collectGlobalRefs` scans both `Resources` and
`Parameters` sections for entries with `$global: true`, collecting their keys
into the globals set.

### Global Section Promotion

`extractGlobalSections` collects six top-level sections from the expanded template
and promotes them into the parent document:

```
Parameters, Outputs, Metadata, Mappings, Conditions, Transform
```

For each entry in these sections:

- If the entry object contains `$global: true`, the entry keeps its original key
  and is promoted as-is (with `$global` stripped from the value).
- Otherwise, the entry key is prefixed with the instance name prefix.

In both cases, refs within the entry's value are rewritten normally. If the parent
document already defines an entry with the same key, the parent's definition takes
precedence and the promoted entry is silently dropped.

### JSON Schema Validator

The validator implements a JSON Schema Draft 7 subset sufficient for custom resource
parameter validation. Supported keywords:

| Keyword                 | Applies to         |
|-------------------------|--------------------|
| `type`                  | all (string or array of types) |
| `enum`                  | all                |
| `required`              | objects            |
| `properties`            | objects            |
| `additionalProperties`  | objects (boolean false only) |
| `items`                 | arrays             |
| `pattern`               | strings            |
| `minimum` / `maximum`   | numbers            |
| `minItems` / `maxItems` | arrays             |
| `minLength` / `maxLength` | strings          |

Boolean schemas (`true` accepts all, `false` rejects all) are supported at the
top level.

**Constraint composition**: When a schema object contains multiple keywords, all
constraints are AND-ed together. Validation proceeds sequentially through keywords;
the first failure short-circuits and returns `Left` immediately.

**Validation pseudocode**:

```
validateSchema :: JSON.Value -> JSON.Value -> Either Text ()
validateSchema schema value = case schema of
    Object obj -> do
        check "type"                 -> matchesType expectedType value
        check "enum"                 -> value ∈ allowedList
        check "required"  (objects)  -> all required keys present
        check "properties" (objects) -> each present property validates against its sub-schema
        check "additionalProperties: false" -> no keys outside "properties"
        check "items"     (arrays)   -> each element validates against item schema
        check "pattern"   (strings)  -> POSIX regex match (max 1024 chars)
        check "minimum"   (numbers)  -> value >= min
        check "maximum"   (numbers)  -> value <= max
        check "minItems"  (arrays)   -> length >= n
        check "maxItems"  (arrays)   -> length <= n
        check "minLength" (strings)  -> Text.length >= n
        check "maxLength" (strings)  -> Text.length <= n
    Bool True  -> Right ()
    Bool False -> Left "Schema rejects all values"
    _          -> Left "Invalid schema: expected object or boolean"
```

**Security control**: Both `AllowedPattern` (in parameter validation) and
`pattern` (in JSON Schema validation) enforce a maximum regex pattern length
of 1024 characters to prevent ReDoS attacks.

---

## User Stories

### US-04-001: Define a Custom Resource Template with $params

**Persona**: Platform Engineer

**Statement**: As a platform engineer, I want to define a YAML template with a
`$params` section so that application teams can instantiate it with their own
values while I enforce guardrails through type, pattern, and schema constraints.

**Acceptance Criteria**:

- A YAML file with a top-level `$params` key is recognized as a custom resource
  template when imported via `$imports`.
- Each entry in `$params` must be a mapping; non-mapping entries produce a parse
  error: `"$params entries must be mappings"`.
- `Name` is required on each param entry. Missing `Name` produces: `"$params entry:
  Name is required"`. A non-string `Name` produces: `"$params entry: Name must be
  a string"`.
- All other fields (`Type`, `Default`, `AllowedValues`, `AllowedPattern`, `Schema`,
  `$global`) are optional.
- A non-sequence `$params` value produces: `"$params must be a sequence"`.
- Template files may contain any combination of `Resources`, `Parameters`,
  `Outputs`, `Mappings`, `Metadata`, `Conditions`, and `Transform` sections
  alongside `$params`.
- Regular AWS resource types and iidy preprocessing directives (`$defs`,
  Handlebars expressions) are fully supported within the template body.

**Logic Flow**:

1. The `$imports` resolver loads the YAML file and inspects the parsed value.
2. If the top-level object contains a `$params` key, the file is classified as a
   custom resource template with its parsed param definitions and raw source text
   stored.
3. The import key is registered as a synthetic type name in the import table.
4. No expansion occurs at import time; expansion is deferred to resource instance
   processing.

**Edge Cases**:

- A template with `$params: []` (empty sequence) is valid. It behaves as a
  macro with no parameters — its resources are expanded and renamed, but no
  parameter extraction or validation is performed.
- A template may contain Handlebars expressions that reference param names.
  Expressions referencing names not present in `$params` resolve to empty string
  during template re-parse (standard Handlebars behavior). The preprocessing
  variable pre-check (ERR_2001) does not fire during custom resource template
  re-parse because the template body is re-parsed in a fresh context where the
  merged parameter map is the entire variable environment, bypassing the
  pre-check that applies to top-level document preprocessing.
- A template may omit `Resources` entirely if it is used only for its `Parameters`
  or `Outputs` promotion behavior.

**Error Scenarios**:

| Condition                         | Error                                      |
|-----------------------------------|--------------------------------------------|
| `$params` not a sequence          | `$params must be a sequence`               |
| Param entry not a mapping         | `$params entries must be mappings`         |
| Param entry missing `Name`        | `$params entry: Name is required`          |
| Param entry `Name` not a string   | `$params entry: Name must be a string`     |

**Complexity**: Low. `parseParams` is a straightforward structural traversal with
no recursive logic.

---

### US-04-002: Instantiate a Custom Resource in a Stack Template

**Persona**: Developer

**Statement**: As a developer, I want to use an imported template as a resource
type in my stack's `Resources` section so that I get a fully expanded set of
CloudFormation resources without manually duplicating the template's internals.

**Acceptance Criteria**:

- Setting `Type` to an import key on a resource entry triggers expansion.
- `Properties` under the resource entry are used as parameter values.
- Required parameters (those with no `Default`) that are absent from `Properties`
  produce an error: `"Required parameter missing: <name>"`.
- The expanded resources appear in the final CloudFormation template under their
  prefixed names.
- The original resource entry (with the synthetic `Type`) is removed from the
  output; only the expanded resources remain.
- Regular AWS resource types coexist in the same `Resources` section and pass
  through unchanged.
- `NamePrefix` on the resource entry overrides the default prefix (which is the
  resource's logical name). Example: `NamePrefix: Custom` produces `CustomQueue`
  instead of `OrderEventsQueue`.

**Logic Flow**:

1. During `Resources` processing, each entry's `Type` is checked against the
   import table.
2. Matching entries are passed to the expansion function with the instance name,
   resource definition, template info, a re-parser function, and the set of
   parent resource names (as additional globals to prevent rewriting references
   to sibling resources).
3. `NamePrefix` is read from the resource definition; falls back to the instance
   logical name.
4. `Properties` are extracted from the resource definition as the provided
   parameter map.
5. Defaults from param definitions fill in any missing keys.
6. The merged parameter map is validated against all param definition constraints.
7. The re-parser is called with the merged params as Handlebars bindings and the
   template's raw body as input.
8. The `Resources` section is collected from the resolved output.
9. Each resource key is prefixed; reference rewriting is applied to each resource value.
10. Promoted global sections are collected.
11. The expansion result is returned; the caller merges expanded resources into the
    parent `Resources` map and merges global sections into the parent document.

**Edge Cases**:

- A resource entry with `Type` matching an import key but missing `Properties` is
  treated as providing no parameters. Defaults fill in; required params without
  defaults cause an error.
- If `NamePrefix` is set but empty string, resources are named with no prefix
  (their original template names). This is valid but likely unintentional.
- An import key that matches an AWS resource type prefix (e.g., an import named
  `AWS::Custom::Foo`) is not valid; `$imports` keys must not use `::` notation
  per the import system rules.

**Error Scenarios**:

| Condition                                | Error                                            |
|------------------------------------------|--------------------------------------------------|
| Required param absent from Properties   | `Required parameter missing: <name>`             |
| Template body fails to parse             | Re-parser error propagated as-is                 |
| No `Resources` section in template       | Expansion produces zero resources (not an error) |
| Circular template expansion              | `Circular template expansion detected: '<type>' is already being expanded` |

**Circular expansion detection**: The caller maintains an `activeExpansions` set
tracking which template types are currently being expanded in the call stack. If
the same type is encountered again (direct or indirect recursion), expansion is
rejected before any parameter processing occurs.

**Complexity**: Medium. The expansion entrypoint coordinates five sub-operations
and must correctly thread the `Either Text` error channel through each.

---

### US-04-003: Reference Rewriting Across Expanded Resources

**Persona**: Platform Engineer, Reviewer

**Statement**: As a platform engineer, I want all internal references within an
expanded template to be automatically rewritten to use prefixed resource names,
so that multiple instances of the same template do not conflict and cross-resource
references remain correct.

**Acceptance Criteria**:

- `!Ref Queue` inside the template becomes `!Ref OrderEventsQueue` when the
  instance name is `OrderEvents`.
- `!GetAtt Queue.QueueName` becomes `!GetAtt OrderEventsQueue.QueueName`.
- `!Sub "${Queue.QueueName}-depth"` becomes
  `!Sub "${OrderEventsQueue.QueueName}-depth"`.
- `Condition: QueueEmpty` becomes `Condition: OrderEventsQueueEmpty`.
- `DependsOn: Queue` becomes `DependsOn: OrderEventsQueue`.
- `DependsOn: [Queue, Alarm]` becomes `DependsOn: [OrderEventsQueue, OrderEventsAlarm]`.
- AWS pseudo-references are never rewritten:
  `AWS::AccountId`, `AWS::NotificationARNs`, `AWS::NoValue`, `AWS::Partition`,
  `AWS::Region`, `AWS::StackId`, `AWS::StackName`, `AWS::URLSuffix`.
- References to names marked `$global: true` are never rewritten.
- References to the consuming resource's own logical name are never rewritten
  (passed in as `additionalGlobals`).
- `${!LiteralText}` inside `!Sub` strings is not treated as a reference and is
  left unchanged.
- In a two-argument `!Sub [template, {VarName: value}]`, keys of the variable
  map are added to the globals set so they are not rewritten in the template
  string.
- Both `Fn::` prefix and `!` short-tag forms of `Ref`, `GetAtt`, `Sub` are
  rewritten identically.

**Logic Flow**:

1. The resolved template is scanned for entries with `$global: true` in
   `Resources` and `Parameters` sections; their names form the globals set.
2. AWS pseudo-references are unioned with collected globals and any additional
   globals passed by the caller.
3. The value tree is walked recursively.
4. At each object node, single-key detection checks for `Ref`, `Fn::GetAtt`,
   `Fn::Sub`, `!Ref`, `!GetAtt`, `!Sub` and dispatches to the appropriate
   rewriter.
5. For all other objects, `Condition` and `DependsOn` fields are handled
   specially; all other fields are recursed into.
6. The central gate: any name starting with `AWS::` or present in the globals
   set is left unchanged; all others are prefixed.

**Edge Cases**:

- A `!Sub` string with no `${...}` interpolations is returned unchanged without
  scanning.
- A malformed `!Sub` string where `${` has no closing `}` is returned unchanged
  (treated as a literal).
- `!GetAtt` with dot notation (`"Queue.QueueName"`) and array notation
  (`["Queue", "QueueName"]`) are both rewritten correctly.
- A resource that `DependsOn` a global resource (e.g., a shared VPC) must be
  marked `$global` on that param or defined in the outer template to avoid
  rewriting.

**Error Scenarios**:

Rewriting is a pure transformation with no failure mode; it silently skips values
it cannot interpret (e.g., non-string `!Ref` targets, non-array/non-string
`DependsOn`).

**Complexity**: Medium-high. The `!Sub` template string parser handles nested
`${...}` patterns, literal `!` escapes, and the two-argument form with variable
map key extension.

---

### US-04-004: Global Section Promotion ($global: true)

**Persona**: Platform Engineer

**Statement**: As a platform engineer, I want to mark certain Parameters, Outputs,
Mappings, Metadata, and Conditions entries with `$global: true` so that they are
promoted into the parent document under their original names and shared across all
instances of the template.

**Acceptance Criteria**:

- Entries with `$global: true` in the template's `Parameters`, `Outputs`,
  `Metadata`, `Mappings`, `Conditions`, or `Transform` sections are promoted to
  the parent document with their original (non-prefixed) key.
- The `$global: true` marker is stripped from the promoted entry's value before
  it appears in the final document.
- Entries without `$global: true` are promoted with the instance prefix prepended
  to their key.
- If the parent document already defines an entry with the same key as a promoted
  global, the parent's definition is kept and the template's version is silently
  dropped.
- Refs within promoted section values are rewritten using the same prefix and
  globals rules as resource values.
- `$global` params in `$params` (as opposed to section entries) cause the param's
  name to be added to the globals set in ref rewriting, preventing its name from
  being prefixed in references.
- `Conditions` entries cannot use `$global: true` in practice because a Condition
  value is the condition expression itself, not a mapping — there is no place to
  embed the marker. Shared conditions must be defined in the outer template.

**Logic Flow**:

1. After parameter resolution and override application, the six promotable section
   names are iterated.
2. For each present section, each entry is processed:
   a. If the entry value contains `$global: true`, the key is preserved as-is.
   b. Otherwise, the prefix is prepended to the key.
   c. `$global` is stripped from the promoted value.
   d. Reference rewriting is applied to the value.
3. The resulting section map is returned as part of the expansion result.
4. The caller merges each section into the parent document, with parent
   definitions taking precedence. In multi-instance scenarios, the parent
   document's original definitions take precedence over ALL instances'
   promotions, and the first instance's promotions take precedence over
   subsequent instances'.

**Section promotion pseudocode**:

```
extractGlobalSections :: Text -> Set Text -> OValue -> Map Text OValue
extractGlobalSections prefix globals (OObject kvs) =
    for each sectionName in [Parameters, Outputs, Metadata, Mappings, Conditions, Transform]:
      if sectionName ∈ kvs:
        prefixAndRewriteSection prefix globals (lookup sectionName kvs)

prefixAndRewriteSection prefix globals (OObject kvs) =
    OObject [ (key', stripGlobal (rewriteRefs prefix globals v))
            | (k, v) <- kvs
            , k /= "$global"                          -- strip top-level $global entries
            , let key' = if isMarkedGlobal v then k    -- $global: true -> keep original key
                         else prefix <> k              -- otherwise prefix
            ]
```

**Edge Cases**:

- A template instantiated twice with the same global Parameter (e.g., `Environment`)
  will attempt to promote it twice. The first promotion writes the key; the second
  is silently dropped. This is the intended behavior for shared parameters.
- A global Output with an `Export` block is promoted as-is. The Export name is
  not prefixed, which may cause conflicts if two instances export the same name.
  Template authors are responsible for ensuring Export names are unique (typically
  by making the export name depend on a param value).
- The `Transform` section is treated as a promotable section. Its value is
  typically a string (`AWS::Serverless-2016-10-31`) rather than a mapping, so
  `$global` marking is not applicable; it is always promoted with prefix. Template
  authors that need a shared Transform should define it in the outer template.

**Error Scenarios**:

Section promotion has no failure mode. Key conflicts are silently resolved in
favor of the parent.

**Complexity**: Medium. The interplay between `$global` in `$params` (affecting
ref rewriting) and `$global` in section entries (affecting key naming) requires
careful distinction.

---

### US-04-005: Override Expanded Resource Properties

**Persona**: Developer

**Statement**: As a developer, I want to use an `Overrides` block on a custom
resource instance to deep-merge additional properties into the expanded template
output, so that I can adjust behavior the template does not expose as a parameter
without forking the template.

**Acceptance Criteria**:

- An `Overrides` key on the resource instance definition is extracted and
  deep-merged into the resolved template value after parameter substitution.
- Deep merge semantics: for nested objects, keys from `Overrides` are merged into
  the base object. For scalar values or arrays, the override value replaces the
  base value entirely.
- `Overrides` values are resolved in the outer (consuming) template context, so
  they can reference `$defs` and `$imports` from the consuming document.
- Overrides can target any section of the template output (`Resources`,
  `Parameters`, `Outputs`, etc.).
- Overrides can set any property on any resource, including properties that conflict
  with param-driven values. No conflict detection is performed.
- After override application, reference rewriting and section promotion proceed
  normally on the merged value.
- If `Overrides` is absent, expansion proceeds identically to the no-override case.

**Logic Flow**:

1. The `Overrides` key is read from the resource instance; absent if not present.
2. After the template is re-parsed and resolved, the overrides value is deep-merged
   into the resolved output if present.
3. Deep merge: for nested objects, overlay keys take precedence over base keys.
   Non-object overlays replace the base value entirely.
4. The merged value is then passed to global ref collection, reference rewriting,
   and section promotion.

**Deep merge pseudocode** (preserves key insertion order):

```
deepMerge :: OValue -> OValue -> OValue
deepMerge (OObject base) (OObject overlay) =
    OObject (mergeKvs base overlay)
  where
    mergeKvs bs []              = bs
    mergeKvs bs ((k, v) : rest) =
      if k ∈ keys(bs)
        then mergeKvs (update k (deepMerge existing v) bs) rest   -- recurse into existing key
        else mergeKvs (bs ++ [(k, v)]) rest                       -- append new key at end
deepMerge _ overlay = overlay   -- scalar/array: overlay replaces entirely
```

**Example**:

```yaml
# Instance
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

The `Overrides.Resources.Queue.Properties` object is deep-merged into
the template's `Queue.Properties`, adding `FifoQueue` and
`ContentBasedDeduplication` alongside any param-driven properties.

**Edge Cases**:

- Overrides that replace a scalar value that was referenced by other resources in
  the template (e.g., replacing a resource name) will not affect already-written
  references. Reference rewriting occurs after override application, so the
  rewritten form is determined by the merged state.
- An `Overrides` block that adds a new resource key to `Resources` will have that
  key prefixed and rewritten along with all other resources.
- Array values in Overrides replace the base array entirely (no array element
  merging). This is consistent with standard deep-merge semantics.

**Error Scenarios**:

No validation is performed on `Overrides` content. Invalid CFN properties will
pass through and fail at CloudFormation deployment time.

**Complexity**: Low-medium. `deepMerge` is a small recursive function; the
complexity is in understanding when to use it versus when a param should be added
instead.

---

### US-04-006: Validate Parameters with Constraints and Schema

**Persona**: Platform Engineer, CI Pipeline

**Statement**: As a platform engineer, I want parameter validation to reject
invalid values at preprocessing time with descriptive error messages, so that
misconfigured stacks are caught before any AWS API call is made.

**Acceptance Criteria**:

- Type validation accepts `String` (case-insensitive: `string`), `Number`
  (`number`), `Object` (`object`). AWS-prefixed types (`AWS::EC2::Image::Id`,
  `List<...>`, `CommaDelimitedList`) pass through without structural validation.
  Unknown types produce: `"Unknown parameter type: <type>"`.
- `AllowedValues` validation checks the provided value against the list using value
  equality. Values not in the list produce:
  `"<name>: value not in AllowedValues"`.
- `AllowedPattern` validation applies a POSIX regex to string values. Non-matching
  strings produce: `"<name>: value does not match AllowedPattern: <pattern>"`.
  Non-string values skip pattern validation silently.
- `Schema` validation delegates to the JSON Schema Draft 7 validator. Failures
  produce: `"Schema validation failed for '<name>': <validator-error>"`.
- Values that are CFN intrinsic expressions (objects with `Ref`, `Fn::Sub`,
  `!Ref`, `!Sub`, etc.) bypass `AllowedValues`, `AllowedPattern`, and `Schema`
  validation entirely. Type validation is also bypassed for CFN intrinsic values.
- Missing required parameters (those with no `Default`) produce:
  `"Required parameter missing: <name>"`.
- Validation errors are reported for the first failing parameter encountered
  (fail-fast via `Either`).

**Logic Flow**:

1. Param definitions are iterated in definition order.
2. For each param, the merged map is checked for the param's name.
3. If absent and no default: error `"Required parameter missing: <name>"`.
4. If absent and default present: pass (default will be used).
5. If present: four validators are applied in sequence:
   a. AllowedValues: list membership check; bypassed for CFN intrinsic values.
   b. AllowedPattern: POSIX regex on string values; bypassed for non-strings and
      CFN intrinsic values.
   c. Type: structural type check; bypassed for CFN intrinsic values.
   d. Schema: JSON Schema validation; bypassed for CFN intrinsic values.
6. A value is considered a CFN intrinsic if it is an object whose key is from the
   CFN intrinsic set (both `Fn::` prefix and `!` short-tag forms).

**CFN intrinsic key set** (exhaustive):

```
Ref, Fn::Sub, Fn::Join, Fn::Select, Fn::If, Fn::GetAtt, Fn::ImportValue, Fn::FindInMap
!Ref, !Sub,   !Join,    !Select,    !If,    !GetAtt,    !ImportValue,    !FindInMap
```

Note: `Fn::GetAZs` and `Fn::Split` are NOT in this set. Values using those
intrinsics will not bypass validation, which matches the Rust implementation.

**Parameter merge and validation pseudocode**:

```
mergeParams :: [ParamDef] -> Map Text OValue -> Map Text OValue
mergeParams defs provided =
    foldl' addDefault provided defs
  where
    addDefault acc pd
      | pdName pd ∈ keys(acc) = acc              -- provided value takes precedence
      | Just def <- pdDefault pd = insert (pdName pd) def acc  -- fill default
      | otherwise = acc                           -- no default, will fail validation if required

validateParams :: [ParamDef] -> Map Text OValue -> Either Text ()
validateParams defs merged = traverse_ validateOne defs
  where
    validateOne pd = case lookup (pdName pd) merged of
        Nothing
          | Just _ <- pdDefault pd -> Right ()    -- has default, ok
          | otherwise -> Left ("Required parameter missing: " <> pdName pd)
        Just val -> do
            validateAllowedValues pd val          -- explicit isCfnRef bypass
            validateAllowedPattern pd val         -- bypassed for non-OString (implicit for CFN intrinsics)
            validateType pd val                   -- explicit isCfnRef bypass
            validateParamSchema pd val            -- explicit isCfnRef bypass

-- Type validation dispatch:
validateType :: ParamDef -> OValue -> Either Text ()
validateType pd val = case pdType pd of
    Nothing                          -> Right ()
    Just "String" | Just "string"    -> expectType isOString "String" (with isCfnRef bypass)
    Just "Number" | Just "number"    -> expectType isONumber "Number" (with isCfnRef bypass)
    Just "Object" | Just "object"    -> expectType isOObject "Object" (with isCfnRef bypass)
    Just t | "AWS:" `isPrefixOf` t   -> Right ()  -- AWS parameter types pass through
           | "List<" `isPrefixOf` t  -> Right ()  -- List<AWS::...> types pass through
           | t == "CommaDelimitedList" -> Right ()
           | otherwise               -> Left ("Unknown parameter type: " <> t)
```

**Note on `AllowedPattern` bypass**: Unlike `AllowedValues`, `Type`, and `Schema`,
`AllowedPattern` does not have an explicit `isCfnRef` guard. Instead, it only
matches `OString` values. CFN intrinsic values are `OObject` and fall through to
the `_nonString -> Right ()` catch-all. The behavioral result is identical (CFN
intrinsics bypass pattern validation), but the mechanism is implicit.

**JSON Schema Keywords Validated**:

| Keyword                 | Error pattern                                               |
|-------------------------|-------------------------------------------------------------|
| `type`                  | `Expected type <t>, got <actual>`                           |
| `enum`                  | `Value not in enum`                                         |
| `required`              | `'<prop>' is a required property`                           |
| `properties`            | `Property '<prop>': <sub-error>`                            |
| `additionalProperties: false` | `Additional property '<prop>' is not allowed`        |
| `items`                 | `Item <n>: <sub-error>`                                     |
| `pattern`               | `String does not match pattern: <pat>`                      |
| `minimum`               | `Value <n> is less than minimum <min>`                      |
| `maximum`               | `Value <n> is greater than maximum <max>`                   |
| `minItems`              | `Array has <n> items, minimum is <min>`                     |
| `maxItems`              | `Array has <n> items, maximum is <max>`                     |
| `minLength`             | `String length <n> is less than minLength <min>`            |
| `maxLength`             | `String length <n> is greater than maxLength <max>`         |

**Edge Cases**:

- An `AllowedValues` list containing items of mixed types (e.g., string and number) is
  valid; the provided value must match one element using value equality.
- A `Schema` with `boolean: false` at the top level rejects all values.
- A `Schema` with `boolean: true` at the top level accepts all values.
- `AllowedPattern` is applied only to `OString` values. If the param type is
  `String` but the value is a CFN intrinsic, the pattern check is skipped.
- JSON Schema `type: integer` is supported by the validator (`isInteger` check on
  `Scientific`) but `pdType` does not have an `Integer` case; integer params
  should use `Number` type with a `Schema` for integer enforcement.

**Error Scenarios**:

| Condition                              | Error message                                              |
|----------------------------------------|------------------------------------------------------------|
| Type mismatch: String param gets number | `<name>: expected String`                                 |
| Value not in AllowedValues             | `<name>: value not in AllowedValues`                       |
| AllowedPattern mismatch                | `<name>: value does not match AllowedPattern: <pat>`       |
| Schema type mismatch                   | `Schema validation failed for '<name>': Expected type <t>` |
| Schema required property missing       | `Schema validation failed for '<name>': '<prop>' is a required property` |
| Schema additionalProperties violation  | `Schema validation failed for '<name>': Additional property '<prop>' is not allowed` |
| Unknown type string                    | `Unknown parameter type: <type>`                           |

**Complexity**: Medium. The CFN intrinsic bypass logic requires `isCfnRef` to
cover both `Fn::` and `!`-prefixed key forms. The JSON Schema validator is a
recursive descent over Draft 7 keywords with 14 keyword implementations.

---

### US-04-007: Multi-Instance Expansion (Same Template, Different Params)

**Persona**: Developer, CI Pipeline

**Statement**: As a developer, I want to instantiate the same custom resource
template multiple times in a single stack with different parameter values, so that
I can create multiple independent copies of a resource pattern without naming
conflicts.

**Acceptance Criteria**:

- Each instance is expanded independently. No state is shared between expansions.
- Each instance's resources are prefixed with that instance's logical name (or
  `NamePrefix` if specified), producing distinct resource names.
- References within each expansion are rewritten using that instance's prefix
  only; they do not cross-reference another instance's resources.
- Global section promotions from all instances are merged into the parent document.
  For entries with the same key, the first instance's promotion wins (parent
  definition takes precedence, and the first expansion writes it as the effective
  parent for subsequent instances).
- An instance with `NamePrefix` that collides with another instance's prefix (or
  with a regular resource name) produces overlapping resource names. No collision
  detection is performed; last-writer-wins in the output resource map.
- Parameter values are independent per instance; changing `QueueLabel` on one
  instance has no effect on another.

**Logic Flow**:

Each instance resource entry is processed independently. The caller accumulates
expanded resource lists and global section maps from all instances, merging them
into the parent document after all expansions complete. The additional globals set
for each instance contains all parent resource names, preventing any cross-instance
reference rewriting.

**Example**:

```yaml
$imports:
  MonitoredQueue: monitored-queue-template.yaml

Resources:
  OrderEvents:
    Type: MonitoredQueue
    Properties:
      QueueLabel: OrderEvents
      AlarmPriority: "P2"
  PaymentEvents:
    Type: MonitoredQueue
    Properties:
      QueueLabel: PaymentEvents
      AlarmPriority: "P1"
```

Produces resources: `OrderEventsQueue`, `OrderEventsQueueDepthAlarm`,
`PaymentEventsQueue`, `PaymentEventsQueueDepthAlarm`. The shared `Environment`
parameter (if `$global: true`) is promoted once; the second promotion is dropped.

**Edge Cases**:

- Two instances that both promote the same non-global Output key will have the
  second instance's Output silently dropped. Template authors should parameterize
  Output names if they need both to appear.
- Instantiating the same template once with default params and once with
  `NamePrefix: Custom` produces differently-prefixed expansions with no conflict,
  provided the prefixes differ.
- Using the same `NamePrefix` on two instances of the same template in the same
  stack produces identical resource names. The final output will contain only the
  last-expanded instance's resources.

**Error Scenarios**:

Each instance expansion fails independently. The first failing expansion short-circuits
further processing and returns the error.

**Complexity**: Low (at the orchestration level). The expansion function is
stateless; multi-instance behavior emerges from calling it once per instance and
accumulating results. The complexity is in the caller's merge logic.

---

## Testing Requirements

### Unit Tests

- `parseParams` with valid sequence of param defs: verifies all fields parsed
  correctly including optional fields absent.
- `parseParams` with non-sequence input: returns error `"$params must be a sequence"`.
- `parseParams` with non-mapping entry: returns error `"$params entries must be mappings"`.
- `parseParams` with missing `Name`: returns appropriate error.
- Param validation with all params provided and valid: passes.
- Param validation with missing required param: returns error `"Required parameter missing: ..."`.
- Param validation with param having a default and not provided: passes.
- AllowedValues validation: provided value in list passes; not in list fails.
- AllowedValues validation with CFN intrinsic value: bypassed (passes).
- AllowedPattern validation: matching string passes; non-matching fails.
- AllowedPattern validation with non-string value: bypassed (passes).
- Type validation for each recognized type (`String`, `Number`, `Object`): correct
  value passes; wrong value fails.
- Type validation for `AWS::` prefix types: always passes.
- Type validation for unknown type: returns error `"Unknown parameter type: ..."`.
- Param merging with all params provided: no defaults inserted.
- Param merging with missing params: defaults filled in.
- Param merging with provided params taking precedence over defaults.

### Expansion Tests

- Full expansion with a minimal template (single resource, one param, no globals):
  verifies resource name prefix and ref rewriting.
- Expansion with `NamePrefix`: verifies custom prefix used instead of instance name.
- Expansion with missing required param: verifies `Left` with correct message.
- Expansion with `Overrides`: verifies deep-merge result in output.
- Expansion producing global sections: verifies `erGlobalSections` map contents.
- Expansion with `$global: true` Parameters entry: verifies entry promoted with
  original key, `$global` stripped from value.
- Expansion with non-global Parameters entry: verifies entry promoted with prefix.
- Expansion with empty `Resources` section in template: produces zero resources.
- Expansion with circular template reference: returns `Left` with circular
  expansion error message.

### Reference Rewriting Tests

- `!Ref Queue` with prefix `OrderEvents`: produces `!Ref OrderEventsQueue`.
- `!Ref AWS::Region`: unchanged.
- `!GetAtt Queue.QueueName` (string form): first component prefixed.
- `!GetAtt` array form: first element prefixed.
- `!Sub` string with `${Queue}`: interpolation prefixed.
- `!Sub` string with `${!Literal}`: left unchanged.
- Two-argument `!Sub` with variable map: variable map keys added to globals,
  template rewritten excluding those keys.
- `Condition` field: string value prefixed.
- `DependsOn` as string: prefixed.
- `DependsOn` as array: each element prefixed.
- Name in the globals set: left unchanged.
- `AWS::AccountId`: not rewritten.
- Name in globals: not rewritten.
- Arbitrary non-global name: rewritten.

### JSON Schema Validation Tests

- `type: string` with string value: `Right ()`.
- `type: string` with number value: `Left` with type error.
- `type: integer` with whole number: `Right ()`.
- `type: integer` with fractional number: `Left`.
- `type: array` accepting multiple types: matches either.
- `enum` with value in list: `Right ()`.
- `enum` with value not in list: `Left`.
- `required` with present property: `Right ()`.
- `required` with absent property: `Left "... is a required property"`.
- `additionalProperties: false` with extra key: `Left`.
- `additionalProperties: false` with no extra keys: `Right ()`.
- `items` schema with valid array: `Right ()`.
- `items` schema with invalid element: `Left "Item N: ..."`.
- `pattern` match: `Right ()`.
- `pattern` mismatch: `Left`.
- `minimum` / `maximum` boundary conditions.
- `minItems` / `maxItems` boundary conditions.
- `minLength` / `maxLength` boundary conditions.
- Boolean schema `true`: `Right ()` for any value.
- Boolean schema `false`: `Left` for any value.
- Invalid schema (not object or boolean): `Left "Invalid schema: ..."`.

### Integration / Snapshot Tests

- Full stack template with one custom resource instance: snapshot of expanded output.
- Full stack template with two instances of same template: snapshot verifying both
  prefixed expansions and single global promotion.
- Template with Overrides: snapshot verifying deep-merge result.
- Template with schema-validated array param: valid case passes, invalid case
  produces error at preprocessing time.
- Consumer with `$global: true` Parameter used by two instances: snapshot verifying
  single promoted entry.

---

## Cross-References

| Document                                          | Relationship                                                  |
|---------------------------------------------------|---------------------------------------------------------------|
| `PRD-03: Import System`                           | `$imports` loads templates; import key becomes synthetic type  |
| `PRD-02: YAML Preprocessing`                      | Handlebars template re-parse with param bindings              |
| `docs/custom-resource-templates.md`               | User-facing documentation, examples, team workflow guidance   |
| Rust source: `~/src/iidy/src/cfn/custom_resources/` | Original implementation; behavioral oracle for edge cases  |
