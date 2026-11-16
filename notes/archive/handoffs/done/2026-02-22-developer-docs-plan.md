# Developer Documentation Plan

## Upstream Rust Docs Inventory

The Rust project has 10 developer-facing docs (~1,457 lines total) in `~/src/iidy/docs/dev/`:

| File | Lines | Category | Description |
|------|-------|----------|-------------|
| architecture.md | 245 | Architecture | High-level pipeline: CLI → stack-args → YAML preprocessing → CFN → output |
| codebase-guide.md | 190 | Guide | File tree navigation, module purposes, quick reference |
| aws-config.md | 296 | Reference | AWS credential resolution, region priority, assume-role |
| output-architecture.md | 268 | Architecture | OutputData enum, renderers, section management, spinners |
| js-compatibility.md | 66 | Reference | Behavioral differences from iidy-js |
| custom-resource-templates.md | 69 | Guide | Custom resource implementation details |
| adr/001-output-sequencing.md | 61 | ADR | Three-layer output architecture |
| adr/002-data-driven-output.md | 59 | ADR | OutputData enum as IR between handlers and renderers |
| adr/003-template-approval.md | 67 | ADR | S3-backed template approval workflow |

Plus SECURITY.md (160 lines) at the docs root — import security model.

## Haskell Docs Plan

Equivalent docs adapted for the Haskell codebase, preserving upstream structure where applicable:

### Core Docs

1. **docs/dev/architecture.md** — High-level architecture overview
   - Pipeline diagram (CLI → YAML → CFN → Output)
   - Key abstractions per layer
   - Monad stack choice (plain IO + explicit CfnContext)
   - Cross-references to other docs

2. **docs/dev/codebase-guide.md** — Module navigation reference
   - File tree with all 80 modules grouped by layer
   - One-line description per module
   - Key entry points

3. **docs/dev/aws-config.md** — AWS configuration resolution
   - Region resolution priority (4 levels)
   - Credential detection priority (6 sources)
   - Profile resolution (4 levels)
   - Assume-role wrapping
   - Display name generation

4. **docs/dev/output-architecture.md** — Output pipeline
   - OutputData enum (26 variants table)
   - OutputDispatch routing
   - InteractiveRenderer / JsonRenderer
   - Section management, spinners, timing
   - Command handler rules

5. **docs/dev/custom-resource-templates.md** — Custom resource implementation
   - 5-phase expansion pipeline
   - Params, ref rewriting, OValue threading

6. **docs/dev/testing-guide.md** — Testing strategy (new, no Rust equivalent)
   - Framework: tasty + hunit + quickcheck
   - 379 tests, fixture patterns, snapshot comparison
   - Mock AWS strategy, test data builders

7. **docs/dev/rust-compatibility.md** — Port compatibility notes
   - Replaces js-compatibility.md (we compare to Rust, not JS)
   - Known divergences from DIVERGENCES.md
   - Library differences (HsYAML vs tree-sitter, etc.)

### ADRs

8. **docs/dev/adr/001-output-pipeline.md** — Data-driven output with OutputData enum
9. **docs/dev/adr/002-ovalue-key-order.md** — OValue for key-order preservation
10. **docs/dev/adr/003-yaml-preprocessing.md** — Two-phase YAML engine with HsYAML
11. **docs/dev/adr/004-custom-implementations.md** — Custom JMESPath, Handlebars, JSON Schema

### Security

12. **docs/SECURITY.md** — Import security model (adapted from upstream)

## Writing Style

- Technical, assumes Haskell knowledge
- Specific file paths and function signatures
- ASCII diagrams for pipelines and file trees
- Tables for enum variants and config resolution
- Cross-references between docs
- Code examples in Haskell (not Rust)

## Key Haskell-Specific Topics to Cover

Things that differ from the Rust implementation:
- **OValue** pattern (no Rust equivalent — Rust's serde_yaml preserves order natively)
- **No async** — Haskell uses forkIO for spinner, no tokio
- **ExceptT** usage patterns (where errors are handled)
- **amazonka DuplicateRecordFields** workarounds
- **HsYAML event API** instead of tree-sitter
- **optparse-applicative** instead of clap
- **tasty** test framework instead of insta snapshots
