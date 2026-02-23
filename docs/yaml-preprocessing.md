# YAML Preprocessing

iidy's preprocessing language reduces boilerplate in CloudFormation templates
and stack configuration files. It operates on YAML data structures, not strings:
every transformation takes valid YAML as input and produces valid YAML as
output. The language is purely functional -- once imports are loaded, all
operations are side-effect-free data transformations.

`$imports` loads external data. `$defs` defines local variables. Tags like
`!$if` and `!$map` transform the data. `{{ }}` expressions interpolate values
into strings.

Use `iidy render <file>` to see the preprocessed output without deploying.

For import type details, see [import-types.md](import-types.md).
For import security restrictions, see [SECURITY.md](SECURITY.md).

Teams that become comfortable with the preprocessor also use `iidy render`
outside of CloudFormation to generate Kubernetes manifests, CI configurations,
and other YAML-based artifacts.

---

## Document structure

A preprocessed document has an optional header and a body:

```yaml
$imports:
  vpc: ./vpc-outputs.yaml

$defs:
  region: us-east-1
  app: myapp

# Everything below $imports/$defs is the body
StackName: "{{ app }}-{{ region }}"
Template: template.yaml
Region: !$ region
Parameters:
  VpcId: !$ vpc.VpcId
```

The header keys (`$imports`, `$defs`) are consumed during preprocessing and do
not appear in the output. The body is the output, with all tags and expressions
resolved.

---

## Tier 1: The Basics

These features cover 80% of real-world usage.

### `$imports`

Key-value pairs where the key becomes a variable name and the value is an
import location string. Imports are loaded and recursively preprocessed before
the body is resolved.

```yaml
$imports:
  vpc: ./vpc-outputs.yaml
  dbHost: ssm:/app/config/database-host
  home: env:HOME
  branch: git:branch
```

Import paths support Handlebars interpolation:

```yaml
$imports:
  config: ./config-{{ environment }}.yaml
```

See [import-types.md](import-types.md) for all supported import sources.

### `$defs`

Local variable definitions. Each definition can reference prior definitions
(let* semantics -- they resolve in order, top to bottom).

```yaml
$defs:
  a: 1234
  b: !$ a           # b = 1234
  name: myapp
  prefix: !$join ["-", [!$ name, !$ a]]  # prefix = "myapp-1234"
```

This differs from iidy-js, which resolves `$defs` in parallel.

### `!$` (variable lookup)

Look up a value from the environment (imports + defs). Dot notation traverses
nested objects.

```yaml
$defs:
  config:
    database:
      host: db.example.com
      port: 5432

db_host: !$ config.database.host
db_port: !$ config.database.port
```

#### Query selector

Append `?query` to a path to filter or drill into the resolved value. This is
useful when importing a large shared config but only needing specific fields.

The query supports three forms:

**Comma-separated keys** -- returns a mapping containing only the listed keys:

```yaml
db_subset: !$ config.database?host,port
# Result: {host: db.example.com, port: 5432}
```

All listed keys must exist in the source mapping -- a missing key produces an
error listing the available keys.

**Error handling:** Applying a query to a non-mapping value (e.g. a string or
sequence) always produces an error.

#### Object form

The object form is equivalent to the `?` syntax. The `query` field accepts the
same comma-separated key syntax described above:

```yaml
db_subset: !$
  path: config.database
  query: "host,port"
```

The object form also supports JMESPath expressions via a `jmespath` field for
more complex queries (projections, filters, multi-select). The `query` and
`jmespath` fields are mutually exclusive.

```yaml
# Multi-select hash -- pick specific keys
db_subset: !$
  path: config.database
  jmespath: "{host: host, port: port}"

# Array projection -- extract a field from each item
service_names: !$
  path: services
  jmespath: "[*].name"

# Filter -- select items matching a condition
enabled: !$
  path: services
  jmespath: "[?enabled].name"
```

See the [JMESPath specification](https://jmespath.org/specification.html) for
the full expression syntax.

#### Bracket notation

Use `[varname]` to do dynamic key lookup:

```yaml
$defs:
  environment: production
  config:
    production: prod-value
    staging: staging-value

value: !$ config[environment]   # resolves to "prod-value"
```

### Handlebars templates

Scalar string values containing `{{ }}` expressions are processed through
Handlebars. The environment (imports + defs) is available as context.

```yaml
$defs:
  app: myapp
  environment: production

name: "{{ app }}-{{ environment }}"
url: "https://{{ app }}.{{ environment }}.example.com"
```

Handlebars interpolation also works inside import paths, `!$join` arguments,
and other string values.

To produce literal `{{` in output, escape with a backslash: `\{{ not a template }}`.

See [Handlebars helpers reference](#handlebars-helpers-reference) for available
helpers.

### `!$if` / `!$eq` / `!$not`

Conditional logic. `!$if` evaluates `test`, returns `then` if truthy, `else`
otherwise.

```yaml
$defs:
  environment: production

log_level: !$if
  test: !$eq [!$ environment, production]
  then: WARN
  else: DEBUG
```

`!$eq` tests equality of two values and returns a boolean:

```yaml
is_prod: !$eq [!$ environment, production]
```

`!$not` negates a boolean value:

```yaml
is_not_prod: !$not
  - !$eq [!$ environment, production]
```

Nested conditionals work for complex logic:

```yaml
instance_type: !$if
  test: !$eq [!$ environment, production]
  then: m5.large
  else: !$if
    test: !$eq [!$ environment, staging]
    then: m5.small
    else: t3.micro
```

There are no `!$and` or `!$or` tags. Use nested `!$if` for compound conditions.

### `!$let`

Introduces local variable bindings for an expression. All keys except `in` are
treated as bindings; `in` holds the expression to evaluate with those bindings
in scope.

```yaml
endpoint: !$let
  protocol: https
  host: api.example.com
  port: 443
  in: !$join ["", [!$ protocol, "://", !$ host, ":", !$ port]]
# Result: "https://api.example.com:443"
```

Bindings can reference variables from the outer scope:

```yaml
$defs:
  environment: production

config: !$let
  env: !$ environment
  maxConnections: !$if
    test: !$eq [!$ environment, production]
    then: 100
    else: 50
  in:
    Host: !$join ["-", [!$ env, db, cluster]]
    MaxConnections: !$ maxConnections
```

### `render:` prefix

When iidy loads `stack-args.yaml`, it always preprocesses that file. But the
CloudFormation template referenced by the `Template` field is only preprocessed
if you add the `render:` prefix:

```yaml
# stack-args.yaml
Template: render:./cfn-template.yaml    # preprocessed before deploy
# Template: ./cfn-template.yaml         # sent to CloudFormation as-is
```

Use `render:` when your template uses iidy tags (`!$map`, `$imports`, etc.).
Omit it for plain CloudFormation templates or templates already processed
by another tool.

### `iidy render`

Preview preprocessed output without deploying:

```
iidy render stack-args.yaml
iidy render cfn-template.yaml
iidy render cfn-template.yaml --format json
```

This is the primary debugging tool. If the output looks wrong, the issue is in
preprocessing. If the output looks right but the deploy fails, the issue is in
CloudFormation.

---

## Tier 2: Collections

These tags transform lists and mappings. They share a common structure with
`items`, `template`, and optional `var` and `filter` keys.

### Common structure

Most collection tags use this format:

```yaml
result: !$map
  items: <sequence to iterate>
  template: <expression applied to each item>
  var: <name for current item, default "item">
  filter: <optional boolean expression, only include truthy>
```

Inside `template` and `filter`, you can reference:
- `!$ item` (or `!$ yourVarName`) -- the current item
- `{{ item }}` or `{{ item.field }}` -- Handlebars interpolation of the item
- `{{ itemIdx }}` (or `{{ yourVarNameIdx }}`) -- zero-based index

### `!$map`

Transforms each element in a list using a template expression. Returns a list
of the same length (or shorter if `filter` is used).

```yaml
$defs:
  ports: [80, 443, 8080]

port_configs: !$map
  items: !$ ports
  var: port
  template:
    port_number: "{{ port }}"
    protocol: tcp
```

**When to use**: You need a 1:1 transformation of list items.

With `filter` to select only matching items:

```yaml
$defs:
  users:
    - {name: alice, role: admin}
    - {name: bob, role: user}
    - {name: charlie, role: admin}

admins: !$map
  items: !$ users
  var: user
  filter: !$eq [!$ user.role, admin]
  template:
    name: !$ user.name
    access_level: full
```

### `!$concat`

Concatenates multiple sequences into one flat list.

```yaml
all_envs: !$concat
  - [dev, test]
  - [staging]
  - [production]
# Result: [dev, test, staging, production]
```

**When to use**: You have several lists and need one combined list.

### `!$merge`

Deep-merges multiple mappings. Later values override earlier ones for
conflicting keys.

```yaml
$defs:
  base_config:
    cpu: 256
    memory: 512
    timeout: 30
  prod_overrides:
    cpu: 1024
    memory: 2048
    replicas: 3

config: !$merge
  - !$ base_config
  - !$ prod_overrides
# Result: {cpu: 1024, memory: 2048, timeout: 30, replicas: 3}
```

**When to use**: You have base settings and environment-specific overrides.

Works with conditional overrides:

```yaml
config: !$merge
  - !$ base_config
  - !$if
      test: !$eq [!$ environment, production]
      then: !$ prod_overrides
      else:
        replicas: 1
```

### `!$concatMap`

Maps each item to a sequence, then concatenates all results into one flat list.
Same format as `!$map`, but each `template` must produce a list.

```yaml
$defs:
  services: [api, web, worker]

endpoints: !$concatMap
  items: !$ services
  template:
    - name: "{{ item }}-internal"
      type: internal
    - name: "{{ item }}-external"
      type: external
# Result: list of 6 items (2 per service)
```

**When to use**: Each input item should produce multiple output items. Common
for generating cross-products:

```yaml
$defs:
  services: [api, web]
  environments: [dev, staging, prod]

deployments: !$concatMap
  items: !$ services
  var: service
  template: !$map
    items: !$ environments
    var: env
    template:
      service: "{{ service }}"
      environment: "{{ env }}"
      name: "{{ service }}-{{ env }}"
# Result: 6 deployment configs (2 services x 3 environments)
```

### `!$mergeMap`

Maps each item to a mapping, then merges all results into one mapping. Same
format as `!$map`, but each `template` must produce a single-key mapping.

```yaml
$defs:
  services:
    - {name: api, port: 3000}
    - {name: web, port: 80}
    - {name: worker, port: 6379}

Resources: !$mergeMap
  items: !$ services
  template:
    !$ item.name:
      host: !$join ["-", [!$ item.name, service]]
      port: !$ item.port
# Result: {api: {host: api-service, port: 3000}, web: {...}, worker: {...}}
```

**When to use**: You need to produce a mapping (not a list) from a list of
inputs. Common for generating CloudFormation `Resources` blocks where each
resource has a unique logical name.

### `!$mapListToHash`

Like `!$mergeMap`, but the template produces a two-element list `[key, value]`
which is converted to a mapping entry, then all entries are merged.

```yaml
lookup: !$mapListToHash
  items: [web, api, worker]
  var: svc
  template:
    - !$ svc
    - !$join ["-", [!$ svc, service]]
# Result: {web: web-service, api: api-service, worker: worker-service}
```

**When to use**: You have a list and want to convert it to a key-value mapping.
Similar to `!$mergeMap` but more concise when the template naturally produces
pairs.

### `!$fromPairs`

Converts a list of `[key, value]` pairs into a mapping. Unlike `!$mapListToHash`,
this does not iterate -- it takes a pre-built list of pairs.

```yaml
obj: !$fromPairs
  - [name, myapp]
  - [version, "1.0"]
  - [port, 3000]
# Result: {name: myapp, version: "1.0", port: 3000}
```

**When to use**: You already have key-value pairs as two-element lists and want
a mapping. Combines well with `!$map` and `!$split`:

```yaml
# Parse "KEY=VALUE,KEY=VALUE" string into a mapping
env_vars: !$fromPairs
  - !$map
      items: !$split [",", "NODE_ENV=production,PORT=3000,DEBUG=false"]
      template: !$split ["=", !$ item]
```

### `!$mapValues`

Transforms each value in a mapping, preserving keys. The loop variable
(default `item`) has `.key` and `.value` properties.

```yaml
$defs:
  service_ports:
    api: 3000
    web: 8080
    db: 5432

configs: !$mapValues
  items: !$ service_ports
  template:
    name: "{{ item.key }}-service"
    port: !$ item.value
    protocol: tcp
# Result: {api: {name: api-service, port: 3000, ...}, web: {...}, db: {...}}
```

**When to use**: You want to transform the values of a mapping without
changing the keys. Contrast with `!$mergeMap` which builds a new mapping from
a list.

### `!$groupBy`

Groups items from a list by a key expression. Returns a mapping where each key
is a group label and each value is a list of items in that group.

```yaml
$defs:
  resources:
    - {name: web-1, type: EC2, env: production}
    - {name: web-2, type: EC2, env: production}
    - {name: db-1, type: RDS, env: production}
    - {name: test-1, type: EC2, env: staging}

by_type: !$groupBy
  items: !$ resources
  key: !$ item.type
# Result: {EC2: [{name: web-1, ...}, {name: web-2, ...}, {name: test-1, ...}], RDS: [{name: db-1, ...}]}
```

The `key` expression is evaluated for each item and used as the group label.
You can build compound keys:

```yaml
by_env_type: !$groupBy
  items: !$ resources
  key: !$join ["-", [!$ item.env, !$ item.type]]
```

**Caveat**: Group ordering is non-deterministic (uses HashMap internally).

### Choosing between collection tags

| I have... | I want... | Use |
|-----------|-----------|-----|
| A list | A transformed list (same length) | `!$map` |
| A list | A flat list (each item produces multiple) | `!$concatMap` |
| A list | A mapping (each item becomes a key) | `!$mergeMap` or `!$mapListToHash` |
| A list of pairs | A mapping | `!$fromPairs` |
| A mapping | Same keys, transformed values | `!$mapValues` |
| A list | Grouped by some property | `!$groupBy` |
| Multiple lists | One combined list | `!$concat` |
| Multiple mappings | One combined mapping | `!$merge` |

---

## Tier 3: Serialization, Strings, and Advanced

### `!$join`

Joins a list of values with a separator. Takes a two-element array:
`[separator, list]`.

```yaml
name: !$join ["-", [myapp, !$ environment, !$ region]]
# Result: "myapp-production-us-east-1"
```

### `!$split`

Splits a string by a delimiter. Takes a two-element array:
`[delimiter, string]`.

```yaml
parts: !$split [",", "apple,banana,cherry"]
# Result: ["apple", "banana", "cherry"]
```

Combines well with other tags:

```yaml
# Parse comma-separated ports into security group rules
rules: !$map
  items: !$split [",", "80,443,8080"]
  template:
    IpProtocol: tcp
    FromPort: !$ item
    ToPort: !$ item
```

### `!$toYamlString`

Serializes a value to a YAML string. `!$string` is a deprecated alias for this tag.

```yaml
config_text: !$toYamlString
  key: value
  list: [1, 2, 3]
# Result: "key: value\nlist:\n- 1\n- 2\n- 3\n"
```

### `!$parseYaml`

Parses a YAML string into a structured value.

```yaml
parsed: !$parseYaml "key: value\nlist:\n  - 1\n  - 2"
# Result: {key: value, list: [1, 2]}
```

### `!$toJsonString`

Serializes a value to a JSON string. Commonly used for CloudFormation
parameters that expect JSON:

```yaml
Value: !$toJsonString
  - database:
      host: db.example.com
      port: 5432
```

### `!$parseJson`

Parses a JSON string into a structured value.

```yaml
parsed: !$parseJson '{"key": "value", "count": 42}'
# Result: {key: value, count: 42}
```

### `!$escape`

Prevents preprocessing of its contents. Plain values (strings, numbers,
mappings, sequences) pass through without tag resolution.

```yaml
literal: !$escape
  key: value
  list: [1, 2, 3]
# Result: {key: value, list: [1, 2, 3]} -- no preprocessing applied
```

---

## CloudFormation tag pass-through

CloudFormation intrinsic function tags are recognized by the parser. Their
inner content is preprocessed (so you can use `!$` lookups inside `!Sub`),
then they pass through to the output as tagged YAML values.

Recognized tags: `!Ref`, `!Sub`, `!GetAtt`, `!Join`, `!Select`, `!Split`,
`!If`, `!Equals`, `!And`, `!Or`, `!Not`, `!FindInMap`, `!ImportValue`,
`!Base64`, `!Cidr`, `!GetAZs`, `!Length`, `!ToJsonString`, `!Transform`,
`!ForEach`.

```yaml
$defs:
  bucketSuffix: assets

Resources:
  MyBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${AWS::StackName}-!$ bucketSuffix"
      Tags:
        - Key: Environment
          Value: !Ref EnvironmentParam
```

In this example, `!$ bucketSuffix` is resolved by iidy during preprocessing,
while `!Sub` and `!Ref` pass through to CloudFormation.

---

## Handlebars helpers reference

Helpers are called inside `{{ }}` expressions. All helpers take positional
parameters.

### Serialization

| Helper | Description | Example |
|--------|-------------|---------|
| `toJson` | Serialize to JSON | `{{ toJson config }}` |
| `toJsonPretty` | Serialize to pretty JSON | `{{ toJsonPretty config }}` |
| `toYaml` | Serialize to YAML | `{{ toYaml config }}` |

Deprecated aliases: `tojson`, `tojsonPretty`, `toyaml` (same behavior, prefer
the camelCase versions).

### Encoding

| Helper | Description | Example |
|--------|-------------|---------|
| `base64` | Base64 encode | `{{ base64 value }}` |
| `urlEncode` | URL-encode | `{{ urlEncode path }}` |
| `sha256` | SHA256 hash (hex) | `{{ sha256 value }}` |
| `filehash` | SHA256 of file contents | `{{ filehash "./template.yaml" }}` |
| `filehashBase64` | Base64-encoded SHA256 of file | `{{ filehashBase64 "./template.yaml" }}` |

### String case

| Helper | Description | Example | Result |
|--------|-------------|---------|--------|
| `toLowerCase` | Lower case | `{{ toLowerCase "Hello" }}` | `hello` |
| `toUpperCase` | Upper case | `{{ toUpperCase "Hello" }}` | `HELLO` |
| `capitalize` | Capitalize first letter | `{{ capitalize "hello" }}` | `Hello` |
| `titleize` | Title case | `{{ titleize "hello world" }}` | `Hello World` |
| `camelCase` | camelCase | `{{ camelCase "my-app" }}` | `myApp` |
| `pascalCase` | PascalCase | `{{ pascalCase "my-app" }}` | `MyApp` |
| `snakeCase` | snake_case | `{{ snakeCase "myApp" }}` | `my_app` |
| `kebabCase` | kebab-case | `{{ kebabCase "myApp" }}` | `my-app` |

### String manipulation

| Helper | Description | Syntax |
|--------|-------------|--------|
| `trim` | Remove leading/trailing whitespace | `{{ trim value }}` |
| `replace` | Replace all occurrences | `{{ replace value "search" "replacement" }}` |
| `substring` | Extract substring | `{{ substring value start length }}` |
| `length` | Length of string, array, or object | `{{ length value }}` |
| `pad` | Right-pad to target length | `{{ pad value targetLength [padChar] }}` |
| `concat` | Concatenate strings | `{{ concat str1 str2 str3 }}` |

### Object access

| Helper | Description | Syntax |
|--------|-------------|--------|
| `lookup` | Get property or array element | `{{ lookup object "key" }}` |

---

## Debugging and Error Messages

Every preprocessing error includes the exact file, line, and column where the
problem occurred, the surrounding YAML context, and a concrete example of how
to fix it. This applies to syntax errors (malformed tags, bad nesting),
semantic errors (undefined variables, type mismatches), and import failures
(missing files, unreachable URIs). The goal is that a human or an AI coding
agent can read the error message and immediately know what to change.

### Use `iidy render`

The `render` command shows preprocessed output:

```
iidy render my-template.yaml
iidy render my-template.yaml --format json
iidy render stack-args.yaml
```

### Error message examples

An undefined variable in a Handlebars expression:

```
Variable error: 'app_name' not found @ stack-args.yaml:6:15 (errno: ERR_2001)
  -> variable not defined in current scope

   5 |
   6 | stack_name: "{{app_name}}-{{environment}}"
     |               ^^^^^^^^^^^ variable not defined

   available variables: environment, region

   For more info: iidy explain ERR_2001
```

A typo in a tag name:

```
Tag error: '!$mapp' is not a valid iidy tag @ template.yaml:5:9 (errno: ERR_4002)
  -> check tag spelling or see documentation for valid tags

   4 |
   5 | result: !$mapp
     |         ^^^^^^
   6 |   items: !$ data
   For more info, run: iidy explain ERR_4002
```

A missing required field, with a correction example:

```
Tag error: 'template' missing in !$map tag @ template.yaml:2:11 (errno: ERR_4002)
  -> add 'template' field to !$map tag

   1 | # !$map with missing template field error
   2 | test_map: !$map
   3 |   items: ["a", "b", "c"]

   example:
   !$map
     items: [1, 2, 3]
     template: "{{item}}"
   For more info, run: iidy explain ERR_4002
```

### Common errors

**"Variable not found"**: The variable name in `!$` or `{{ }}` does not exist
in the current scope. Check spelling and ensure the variable is defined in
`$imports` or `$defs`.

**"Env-var X not found"**: An `env:` import references an environment variable
that is not set. Either set the variable or provide a default: `env:VAR:default`.

**"bad import"**: A file import path cannot be resolved. Check that the path is
correct relative to the importing document, not relative to the working
directory.

**Tag nesting**: YAML tags cannot be placed directly after another tag on the
same line. Use a newline and indentation:

```yaml
# Wrong:
value: !$if !$eq [a, b]

# Right:
value: !$if
  test: !$eq [a, b]
  then: yes
  else: no
```
