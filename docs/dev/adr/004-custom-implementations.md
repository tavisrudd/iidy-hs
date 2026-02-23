# ADR 004: Custom JMESPath, Handlebars, and JSON Schema Implementations

## Status

Accepted (2025-02-22)

## Context

iidy requires three text/data processing capabilities for which the
Haskell ecosystem lacks suitable libraries:

**JMESPath**: A query language for JSON, used in iidy for extracting
values from CloudFormation outputs and AWS API responses. No Haskell
JMESPath library exists on Hackage. The closest alternative would be
shelling out to a Python or JavaScript implementation, which would add
a runtime dependency and process overhead.

**Handlebars**: A templating language used in iidy YAML files for
variable interpolation, environment access, and data transformation.
The available Haskell packages (`stache`, `mustache`) implement
Mustache, which is a subset of Handlebars. They do not support custom
block helpers, and iidy relies on 28 custom helpers (`toJson`,
`toYaml`, `filehash`, `env`, arithmetic operators, etc.).

**JSON Schema**: Used for validating iidy configuration files and stack
arguments against user-provided schemas. The primary Haskell package
(`hjsonschema`) is deprecated and does not support Draft 7, which is
the version iidy's schemas target.

## Decision

We implement all three from scratch as internal modules:

**JMESPath** (`Iidy.JmesPath`, ~600 LOC): A recursive descent parser
and tree-walking evaluator covering the operations iidy actually uses:
field access, indexing, projections, multi-select lists/hashes, pipe
expressions, comparisons, and built-in functions (`length`, `keys`,
`values`, `sort_by`, `contains`, `type`, `to_string`, `to_number`,
`join`, `not_null`). Does not implement the full JMESPath compliance
test suite -- targets iidy's use cases specifically.

**Handlebars** (`Iidy.Handlebars`, ~500 LOC): A parser for Handlebars
syntax (`{{...}}`, `{{#if}}`, `{{#each}}`, partials) and a renderer
with 28 registered helpers. Helpers cover: environment variables
(`env`, `envOrElse`), data format conversion (`toJson`, `toYaml`),
file operations (`include`, `filehash`, `filehashBase64`), string
manipulation (`replace`, `lowercase`, `uppercase`), arithmetic
(`add`, `subtract`, `multiply`, `divide`), and CloudFormation-specific
operations (`stackOutput`, `stackExport`). New helpers can be
registered without modifying the parser.

**JSON Schema** (`Iidy.JsonSchema`, ~170 LOC): A Draft 7 validator
covering the keywords iidy schemas use: `type`, `properties`,
`required`, `additionalProperties`, `items`, `enum`, `const`,
`anyOf`, `allOf`, `oneOf`, `not`, `$ref` (local definitions only),
`minLength`, `maxLength`, `minimum`, `maximum`, `pattern`,
`minItems`, `maxItems`, and `format`. Does not implement remote `$ref`
resolution, `$id`-based scoping, or output formats like
`contentEncoding`.

## Consequences

### Benefits

- **Feature parity with Rust**: All three implementations pass the
  same test cases as the Rust originals. Handlebars helpers produce
  identical output. JMESPath queries used in iidy templates evaluate
  correctly. Schema validation catches the same errors.
- **No external dependencies**: No C libraries, no runtime
  interpreters, no additional binaries on PATH. The entire processing
  pipeline is pure Haskell.
- **Full control over behavior**: Edge cases can be matched to the
  Rust implementation exactly. For instance, iidy's Handlebars treats
  `undefined` variables as empty strings rather than raising errors,
  which differs from the Handlebars.js spec but matches the Rust
  behavior.
- **Small footprint**: Combined, the three implementations total
  roughly 1,300 lines of code -- less than many single library
  dependencies would add to the build.

### Trade-offs

- **Maintenance burden**: Bug fixes and feature additions to these
  subsystems fall on the project maintainers rather than upstream
  library authors. Any future iidy features requiring new JMESPath
  functions or JSON Schema keywords will need manual implementation.
- **Potential spec gaps**: The implementations cover iidy's usage
  patterns, not the full specifications. A user constructing a novel
  JMESPath expression or JSON Schema keyword outside iidy's typical
  patterns may hit unsupported features. Error messages in such cases
  indicate what is unsupported.
- **No community review**: Unlike widely-used libraries, these
  implementations have not been battle-tested across many projects.
  The 379-test suite and snapshot matching provide confidence but are
  not a substitute for broad usage.
