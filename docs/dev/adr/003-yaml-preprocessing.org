# ADR 003: Two-Phase YAML Engine with HsYAML

## Status

Accepted (2025-02-22)

## Context

iidy's core function is YAML preprocessing: resolving imports, expanding
`$defs` references, processing custom tags (like `!Sub`, `!GetAtt`), and
evaluating handlebars expressions -- all while tracking source positions
for error messages.

The Rust version uses `tree-sitter-yaml` for parsing, which provides a
concrete syntax tree with byte-accurate position information. No
maintained Haskell bindings for tree-sitter-yaml exist. The available
Haskell YAML libraries are:

- **yaml/libyaml**: Fast C-based parser, but exposes only a flat event
  stream with limited position info. Widely used but low-level.
- **HsYAML**: Pure Haskell YAML 1.2 parser with an event-based API that
  includes source positions on every event. Also provides a higher-level
  loader, but the event API gives the control needed for custom AST
  construction.

Error messages with accurate file/line/column positions are essential:
the project requires matching 49 error snapshots from the Rust reference
implementation.

## Decision

We use HsYAML's event-based API with a custom two-phase processing
architecture:

**Phase 1 -- Structural Resolution**:
- Parse YAML source into an event stream via HsYAML.
- Build a custom AST (`OValue` with position annotations) from events.
- Resolve `$imports` by loading referenced files (local or S3) and
  recursively parsing them. A `LoadImportFn` callback is injected for
  testability -- tests provide a pure map-based loader, production code
  uses IO-based file/S3 loading.
- Expand `$defs` / `$ref` references within the document.

**Phase 2 -- Value Transformation**:
- Walk the AST to resolve YAML tags (`!Sub`, `!Ref`, `!GetAtt`, etc.)
  into their CloudFormation intrinsic function representations.
- Evaluate handlebars expressions (`{{env "FOO"}}`, `{{$var}}`) using
  the custom handlebars engine with 28 registered helpers.
- Perform custom resource expansion for `Custom::` resource types.

Both phases propagate source position metadata so that errors at any
stage can report the originating file, line, and column.

## Consequences

### Benefits

- **Position-accurate error messages**: Every error references the exact
  source location. All 49 error snapshots match the Rust reference,
  confirming positional accuracy.
- **No native dependency**: HsYAML is pure Haskell, avoiding C FFI
  complications and simplifying the Nix build.
- **Testable import resolution**: The `LoadImportFn` injection point
  allows unit tests to exercise the full import pipeline without
  touching the filesystem or network.
- **YAML 1.2 compliance**: HsYAML implements the YAML 1.2 spec. A
  YAML 1.1 auto-detection layer was added on top for backward
  compatibility with older CloudFormation templates that rely on 1.1
  boolean semantics (`yes`/`no`/`on`/`off`).

### Trade-offs

- **Event API is low-level**: Building a custom AST from a stream of
  `MappingStart`, `Scalar`, `SequenceEnd` events requires careful
  state management. This is roughly 400 lines of recursive descent
  over events, compared to the few lines needed with a tree-based API.
- **Custom AST construction**: Because we build our own AST rather than
  using a library-provided tree, we own the full complexity of anchor
  resolution, tag handling, and merge key (`<<`) support.
- **Two-pass overhead**: The document is traversed twice. For the size
  of CloudFormation templates (typically under 10,000 lines), this is
  not measurable. The AWS API calls dominate all runtime costs.
- **YAML 1.1 compatibility layer**: The auto-detection of YAML 1.1
  boolean values adds a pre-processing step and edge cases. This was
  necessary to match Rust behavior but adds maintenance surface.
