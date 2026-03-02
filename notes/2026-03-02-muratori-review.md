# Architecture Review: Casey Muratori Lens

_"Clean code is not the goal. Performance is not the goal. The goal is to solve the problem."_

Muratori's perspective: software engineering is drowning in indirection, abstraction, and ceremony. Code should do work, not delegate work. The measure of architecture is not how pretty the module graph looks — it's how fast the program runs, how much code there is, and whether the complexity is proportional to the problem being solved.

The question is blunt: **is this codebase doing too much to accomplish too little?**

---

## 1. The Problem Is Simple. The Solution Is 85 Modules.

Let's be clear about what iidy does:

1. Read a YAML file.
2. Substitute some variables (from env vars, SSM, files, etc.).
3. Evaluate some template expressions.
4. Emit a CloudFormation-compatible YAML document.
5. (Optionally) call `aws cloudformation create-stack` with it.

That's it. It's a preprocessor and a CLI wrapper around the AWS SDK.

The codebase has **85 source modules**, ~15,000 LOC of Haskell, ~960 tests, 12 developer documentation files, 4 ADRs, and a WORKPLAN that tracks 15 phases of development.

For comparison: `envsubst` (simple variable substitution in files) is ~200 lines of C. `jq` (a complete JSON query language with lexer, parser, evaluator, and pretty-printer) is ~13,000 lines of C — and it handles a far more general problem space.

How did we get here?

---

## 2. Abstraction Tax: The Layer Cake

The path from "read YAML" to "emit YAML" passes through:

```
ByteString                    [file I/O]
  → HsYAML event stream      [external parser]
  → YamlAst (12 constructors) [our parser, ~400 LOC]
  → OValue (6 constructors)   [resolver, ~800 LOC]
  → Value (aeson, 6 cases)    [for JMESPath/Handlebars]
  → OValue                    [back from JMESPath]
  → Text                      [emitter, ~300 LOC]
```

Six representations for the same data. Three format conversions. Two custom value types. A 12-constructor AST that exists between the external YAML parser's output and the 6-constructor resolved value type.

Each layer is clean. Each conversion is well-defined. And each adds code, adds potential bugs, and adds CPU cycles. The `OValue ↔ Value` round-trip in the JMESPath path is the most egregious — converting ordered lists to hash maps and back just because the JMESPath evaluator was written against aeson's `Value`.

**What a minimal implementation looks like:**

1. Use HsYAML's tree API (not event API) directly. No custom AST.
2. Walk the tree once, substituting as you go.
3. Emit directly from the walked tree. No intermediate `OValue`.

That's 3 representations (HsYAML tree → walked tree → text), not 6. You lose source-location precision in error messages (because the tree API doesn't give byte offsets) and you lose key-order control (because HsYAML's tree might not preserve it). But you're also ~5000 LOC lighter.

---

## 3. The Module Count Disease

85 modules means 85 files to navigate, 85 module headers, 85 import sections, and a module DAG that requires documentation to understand.

Some of these modules are unavoidably necessary:
- `Yaml.Parser` (custom parser for tag recognition)
- `Yaml.Resolution.Resolver` (the evaluator)
- `Yaml.Emitter` (custom emitter for key-order preservation)
- `Cfn.StackOperations` (AWS API calls)
- `Cli.Parser` (argument parsing)

But many exist because of organizational convention rather than engineering necessity:

| Module | LOC | Does it need to be its own module? |
|--------|----:|-------------------------------------|
| `Iidy.Constants` | ~20 | No. Inline the constants where used. |
| `Iidy.Cfn.Status` | ~50 | No. Put it in `Cfn.Types`. |
| `Iidy.Cfn.TemplateHash` | ~30 | No. It's one function. |
| `Iidy.Output.Status` | ~40 | No. Put it in `Output.Color`. |
| `Iidy.Output.Terminal` | ~30 | No. Put it in `Output.Manager`. |
| `Iidy.Output.Theme` | ~20 | No. Put it in `Output.Color`. |
| `Iidy.Output.Renderer` | ~10 | No. It's a type alias. |
| `Iidy.Confirm` | ~40 | No. Put it in `Cli`. |
| `Iidy.Yaml.Detection` | ~30 | No. Put it in `Yaml.Parser`. |
| `Iidy.Yaml.PathTracker` | ~48 | No. Put it in `Yaml.Errors.Enhanced`. |
| `Iidy.Yaml.Location` | ~15 | No. Put it in `Yaml.Ast`. |

That's 11 modules that could be folded into their neighbors with zero loss of clarity. The project instructions say "try to keep modules under ~300-500 LOC" — but the cure (dozens of tiny modules) is worse than the disease (one 600-LOC module).

---

## 4. Custom Implementations of Existing Things

The codebase contains custom implementations of:

| Feature | Custom LOC | Existing package |
|---------|----------:|------------------|
| JMESPath evaluator | ~600 | `jmespath` (Haskell, abandoned) or just shell out |
| Handlebars engine | ~400 | `mustache` (close enough) |
| JSON Schema Draft 7 | ~170 | `hjsonschema`, `aeson-schema` |
| SNTP client | ~100 | `ntp` package, or `ntpdate` via subprocess |
| YAML emitter | ~300 | `HsYAML` has an emitter, or use `yaml` |

That's ~1,570 LOC of custom language infrastructure. The JMESPath and Handlebars engines are the most significant — they're real language implementations with parsers, ASTs, and evaluators.

The justifications are documented:
- JMESPath: the Haskell `jmespath` package is abandoned and doesn't match the needed API.
- Handlebars: `mustache` doesn't support the helper registry pattern.
- JSON Schema: no lightweight Draft 7 validator in the Haskell ecosystem.
- NTP: avoid a heavy dependency for 100 lines of work.
- YAML emitter: preserve key ordering, which `HsYAML`'s emitter doesn't guarantee.

Each justification is reasonable in isolation. But collectively, the project has built **five custom implementations of standardized formats/protocols.** That's five things where bugs are your bugs, not upstream's. Five things where spec compliance is your responsibility. Five things where you've diverged from the ecosystem.

The JMESPath implementation is the clearest example: it's a partial implementation of a specified language, the partiality isn't documented, and users will discover the gaps at runtime.

---

## 5. The Output Pipeline: Over-Engineered for the Problem

The output pipeline has:
- `OutputData` — a 27-variant sum type
- `OutputDispatch` — a 2-variant dispatch type (Interactive, JSON)
- `InteractiveRenderer` — an 11-field record with IORef + 4 TVars
- `Renderers.Interactive.Sections` — 473 lines of per-variant rendering functions
- `Renderers.Json` — per-variant conversion to aeson `Value` for JSONL output
- `Output.Manager` — dispatch, cleanup, mode resolution
- `Output.Color` — theming with 4 theme variants
- `Output.Spinner` — background-thread animation with timing
- `Output.Status` — status categorization for coloring

That's **~2,000 LOC** for the output layer. Almost 15% of the codebase is dedicated to displaying information on a terminal.

What does the Rust implementation do? Roughly the same thing, because iidy-hs is a port. But the question stands: does a CloudFormation CLI need a themeable, JSONL-capable, spinner-animated, section-based rendering engine with 27 structured output types?

Or could it just... print strings?

```haskell
putStrLn $ "Creating stack: " <> stackName
putStrLn $ "Status: " <> status
putStrLn $ "Resources:"
forM_ resources $ \r -> putStrLn $ "  " <> rName r <> " (" <> rType r <> ")"
```

The structured output pipeline exists to support JSON output mode and testability. Fair. But the cost is that every new piece of output requires: a new `OutputData` constructor, a new record type, a new interactive renderer function, a new JSON converter function, and test builders. The `OdRawOutput !Text` escape hatch exists because this ceremony is too heavy for simple commands.

---

## 6. What Actually Matters: Performance

Nobody has measured it. There are no benchmarks. No profiling. No measurement of:
- Template preprocessing time for large templates
- Memory usage during resolution
- AWS API latency vs. preprocessing latency
- Startup time (GHC runtime initialization)

For a CLI tool, startup time matters. The Rust binary starts in ~5ms. The Haskell binary (dynamically linked, 12MB) has GHC runtime overhead. Has anyone measured whether the preprocessing is the bottleneck, or whether it's AWS API latency?

If it's AWS latency (it almost certainly is — CloudFormation operations take seconds to minutes), then the entire YAML preprocessing pipeline could be 10x slower and nobody would notice. In that case, the custom JMESPath engine could have been a subprocess call to `jp` or a slower but spec-complete implementation, and the custom YAML emitter could have been the standard one with a post-processing pass to fix key order.

The optimization effort is in the wrong place. `OValue`'s `O(n)` lookup is defended with a cache-locality argument, but there are no benchmarks proving it matters. The custom SNTP client exists to avoid a dependency, but NTP resolution happens once per operation at startup.

---

## 7. The Test Suite: Impressive but Expensive

958 tests. That's admirable coverage for a 15k LOC project. But what's the maintenance cost?

- 42 property tests generate random inputs — they occasionally find real bugs but mostly confirm that format helpers don't crash.
- 35 fixture tests compare against expected output files — they catch regressions but require manual updates when output format changes.
- 49 error snapshot tests compare against Rust output — they're the highest-value tests (differential testing), but they live outside `cabal test`.
- The integration test module creates builders for all 27 `OutputData` types — that's 27 data constructors that must be kept in sync with the types.

The test-to-code ratio is roughly 1:2 (tests are probably ~7k LOC, source is ~15k LOC). Every change to a type, every new output variant, every formatting tweak requires updating tests in multiple places.

Is this the right trade-off for a CloudFormation preprocessor? It depends on whether this tool's correctness matters more than its development velocity. For infrastructure tooling, correctness matters a lot. But the test infrastructure itself is a significant fraction of the total complexity.

---

## 8. What Would a Muratori-Style Implementation Look Like?

Start from the problem, not the architecture:

1. **One file for YAML preprocessing.** Read YAML (via `yaml` package, tree API). Walk the tree. Substitute variables. Emit YAML. No custom AST. No OValue. Maybe 500-800 LOC.

2. **One file for AWS operations.** Call `amazonka` directly. Print results to stdout. No output pipeline, no dispatching, no renderers. Maybe 400-600 LOC for all 14 commands.

3. **One file for CLI parsing.** Parse args, dispatch to the right function. 200-300 LOC.

4. **Use existing implementations** for JMESPath (shell out to `jp`), Handlebars (use `mustache` with minor adaptation), JSON Schema (shell out to `ajv` or skip it and let CloudFormation validate), NTP (shell out to `ntpdate`).

Total: maybe 1,500-2,000 LOC. You lose: structured JSON output mode, themed terminal output, error messages with source-location carets, property-based testing, and behavioral equivalence with the Rust implementation. You gain: a codebase that any single developer can hold in their head.

---

## 9. The Counter-Argument (Being Fair)

This is a **complete port** of a production tool. The Rust original has 16,615 LOC across 96 modules. The Haskell port has ~15,000 LOC across 85 modules. The port is actually _smaller_ than the original while being _feature-complete_.

The 27 `OutputData` variants exist because the Rust implementation has them. The custom JMESPath engine exists because the Rust implementation uses one (via the `jmespath` crate). The error display pipeline exists because iidy's error messages are a user-facing feature, not just debugging output.

The project instructions are explicit: "This is a COMPLETE port. Every Rust feature gets ported. No shortcuts, no dropping features." Given this constraint, the architecture is reasonable. The module structure mirrors Rust's. The test suite verifies equivalence.

Muratori's critique applies more to the _design of iidy itself_ (across both implementations) than to the Haskell port specifically. The question "does a CloudFormation preprocessor need all this?" should have been asked in the original Rust implementation. The Haskell port is faithfully reproducing the answer that was already given.

---

## 10. What's Genuinely Lean

**The import loaders are single-purpose and small.** Each is 40-80 LOC. They do one thing: fetch content from a source. No inheritance hierarchies, no factory patterns.

**The resolver is a single function** (`resolveAst`) with cases for each tag. No visitor pattern, no double dispatch. Just pattern matching. This is the leanest way to write an interpreter in Haskell.

**The CLI dispatch is a flat `case` statement.** 200 lines of direct `case` matching in `Main.hs`. No command registry, no plugin system, no reflection. You can read it top to bottom.

**The YAML engine's two-phase design** keeps IO out of the resolver, which means the resolver is fast (no blocking on I/O) and testable (no mocking). This is architecture that serves performance, not architecture for architecture's sake.

---

## Verdict

This codebase is over-architected relative to its problem domain but correctly-architected relative to its actual requirement (complete behavioral equivalence with a 16k-LOC Rust implementation). The question is which frame you use to evaluate it.

**If you evaluate it as "a tool that preprocesses YAML and calls AWS APIs":** it's 5-10x more code than necessary. 85 modules for what is fundamentally a template expander with an API client.

**If you evaluate it as "a faithful port of a production tool with 98 snapshot tests to match":** it's appropriately sized. The module count reflects the Rust original's structure. The test count reflects the behavioral equivalence requirement. The custom implementations reflect the Rust implementation's choices.

Muratori would say: the problem was over-engineered in Rust, and then the over-engineering was faithfully ported to Haskell. The six-representation data pipeline, the 27-variant output type, the themed renderer — these are solutions looking for problems. But they're the same solutions the Rust implementation chose, and the port's job was to match, not redesign.

The path forward, if you want to _reduce_ complexity: question the feature requirements themselves, not the implementation. Does the JSON output mode get used? Does anyone use the custom resource system? Are the 22 preprocessing tags all necessary, or do users use 5 of them? Trimming features reduces code more than trimming abstractions ever will.

---

## Post-Review Status Updates (Session 46, 2026-03-02)

_These annotations were added after the review to track which findings have been addressed._

Muratori's review is largely philosophical/structural critique rather than specific bug reports. Most findings question the overall engineering approach (faithful port of a complex tool) rather than identifying fixable issues. The session 45-46 fixes are mapped where relevant.

| #  | Finding                                                     | Status              | Notes                                                                                                              |
|----|-------------------------------------------------------------|---------------------|--------------------------------------------------------------------------------------------------------------------|
| 1  | 85 modules for a simple problem                             | WONT FIX            | By design — faithful port of 96-module Rust codebase. Module count is a consequence of the "complete port" requirement, not an accident. |
| 2  | Abstraction tax / 6 representations for data                | WONT FIX            | Each representation serves a purpose: key-order preservation (OValue), source locations (YamlAst), ecosystem compat (aeson Value). Reducing representations would sacrifice features. |
| 3  | Module count disease (11 mergeable modules identified)      | OPEN                | Valid observation. Modules like Constants, TemplateHash, Location could be folded into neighbors. Not addressed in sessions 45-46. Note: Conversion.hs was *split* (not merged) per Gemini review in session 42, going in the opposite direction. |
| 4  | Custom implementations (JMESPath, Handlebars, etc.)         | WONT FIX            | Each custom impl has documented justification (abandoned packages, missing features, spec compliance). Session 45-46 added 8 property tests for JMESPath and Handlebars correctness, strengthening confidence in the custom impls. |
| 5  | Output pipeline over-engineered                             | WONT FIX            | Required for JSON output mode, testability, and Rust behavioral equivalence. `OdRawOutput` escape hatch was added intentionally in session 42 for non-CFN commands. |
| 6  | No performance measurement / benchmarks                     | OPEN                | No benchmarks were added. Valid critique — startup time and preprocessing latency remain unmeasured. |
| 7  | Test suite impressive but expensive (maintenance cost)      | PARTIALLY ADDRESSED | Session 45-46 added 24 error content tests (full 51-fixture coverage) and 8 edge-case property tests. These increase coverage but also increase the maintenance surface Muratori flags. Snapshot gap audit documented. |
