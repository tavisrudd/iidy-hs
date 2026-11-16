# ADR 002: OValue for YAML Key-Order Preservation

## Status

Accepted (2025-02-22)

## Context

CloudFormation templates are YAML documents where key ordering carries
meaning to human readers and, critically, to snapshot-based testing. The
Rust version uses `serde_yaml` which preserves insertion order natively
through `IndexMap`. On the Haskell side, aeson's `Value` type uses
`KeyMap` (backed by `HashMap`), which provides no ordering guarantees.

Early prototypes using aeson `Value` throughout the pipeline produced
valid CloudFormation but failed snapshot comparison: keys appeared in
hash-determined order rather than the source order expected by the Rust
reference snapshots (37 render snapshots, 49 error snapshots).

The project requires exact byte-level output matching against the Rust
binary for verification. Any key reordering causes snapshot failures
that are tedious to distinguish from genuine formatting bugs.

## Decision

We introduce a custom `OValue` type that mirrors aeson's `Value` but uses
an association list `[(Text, OValue)]` for objects instead of `HashMap`:

```haskell
data OValue
  = ONull
  | OBool Bool
  | ONumber Scientific
  | OString Text
  | OArray (Vector OValue)
  | OObject [(Text, OValue)]
```

`OValue` is threaded through the entire YAML processing pipeline:
parsing, import resolution, `$defs` substitution, tag processing,
handlebars expansion, custom resource expansion, and final YAML emission.

Conversion functions (`oValueToValue`, `valueToOValue`) exist at the
boundaries where aeson `Value` is required -- specifically for JSON
Schema validation, JMESPath evaluation, and aeson-based serialization.

The custom YAML emitter operates directly on `OValue`, writing keys in
the order they appear in the association list.

## Consequences

### Benefits

- **Exact snapshot matching**: All 37 render snapshots and 49 error
  snapshots match the Rust reference output byte-for-byte (modulo
  documented divergences unrelated to key ordering).
- **Source fidelity**: Templates round-trip through the pipeline with
  keys in their original authored order, which preserves readability
  and diff-friendliness for users.
- **Deterministic output**: Repeated runs produce identical output
  regardless of GHC version or platform hash seed behavior.

### Trade-offs

- **O(n) key lookup**: Association list lookup is linear in the number
  of keys, compared to O(log n) or O(1) for map-based representations.
  CloudFormation objects are typically small (under 20 keys), so this
  has no measurable impact.
- **Consistency discipline**: All pipeline code must use `OValue`, not
  aeson `Value`, for intermediate representations. Accidentally using
  `Value` in the middle of the pipeline silently destroys key order.
  This was caught several times during development.
- **Conversion overhead at boundaries**: Moving between `OValue` and
  `Value` requires traversal of the entire tree. This happens at a
  small number of well-defined boundary points (schema validation,
  JMESPath queries) and is not performance-sensitive.
- **No standard typeclass instances**: `OValue` does not get free
  `FromJSON`/`ToJSON` instances. Custom parsing and serialization logic
  is required, though this also gives full control over formatting.
