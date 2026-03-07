# ADR 001: Data-Driven Output Pipeline

## Status

Accepted (2025-02-22)

## Context

iidy-hs must support multiple output formats from single command logic:
interactive terminal output with ANSI colors and spinners, structured JSON
for machine consumption, and plain text for piped/non-TTY contexts. The Rust
version solved this with an `OutputData` enum serving as an intermediate
representation -- commands emit semantic data, and renderers translate that
data into a specific format.

A naive approach (commands calling `putStrLn` directly) would tangle
formatting logic with business logic, making it impossible to test output
offline, switch formats at runtime, or ensure all commands produce consistent
output. Every new output format would require touching every command.

The port needed to replicate the Rust architecture faithfully while fitting
Haskell idioms.

## Decision

We adopt a data-driven output pipeline with three components:

1. **OutputData**: A sum type representing every semantic piece of
   output the system can produce (e.g., `OdSectionHeading`, `OdStackEvent`,
   `OdCommandMetadata`, `OdError`). Commands construct and emit these values
   without knowledge of how they will be rendered.

2. **OutputDispatch**: A routing layer created via `mkOutputDispatch` that
   accepts `OutputData` values and forwards them to the active renderer.
   Commands receive an `emitOutput :: OutputData -> IO ()` callback threaded
   through `CfnContext`. The dispatch is configured once at startup based on
   `--output` flag and TTY detection.

3. **Renderers**: `InteractiveRenderer` produces styled terminal output with
   ANSI codes, section structure, and spinner integration.  `JsonRenderer`
   converts each `OutputData` into a JSON object and writes one object per
   line. Both implement exhaustive pattern matching over all variants.

All command output flows through `renderOutput`. Direct `putStrLn` calls are
prohibited in command implementations.

## Consequences

### Benefits

- **Offline testability**: Output can be tested by capturing emitted
  `OutputData` values and comparing against expected sequences, with no
  terminal or AWS connection required. Integration tests use test data
  builders for all variants.
- **Compiler-enforced completeness**: Adding a new `OutputData` variant
  triggers exhaustiveness warnings in both renderers, ensuring nothing is
  silently dropped.
- **Clean separation of concerns**: Command logic knows nothing about ANSI
  codes, JSON encoding, or TTY detection. Renderers know nothing about AWS
  or CloudFormation.
- **Format extensibility**: Adding a new output format (e.g., YAML, CSV)
  requires only a new renderer module -- no command code changes.

### Trade-offs

- **Indirection cost**: Every piece of output passes through an additional
  layer of allocation and dispatch rather than going directly to the terminal.
  In practice this is negligible compared to AWS API latency.
- **Variant synchronization**: All variants must be handled in every
  renderer. Adding a variant requires updating multiple modules. The compiler
  catches omissions, but the manual work scales linearly.
- **Semantic granularity**: Choosing the right level of abstraction for
  variants requires judgment. Too fine-grained creates noise; too coarse
  loses formatting flexibility. The current variant set mirrors the Rust
  version and has proven sufficient.
