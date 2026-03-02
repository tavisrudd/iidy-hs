# Architecture Review: Shriram Krishnamurthi Lens

_"You've designed a programming language. The question is whether you know it."_

Shriram Krishnamurthi's perspective: every configuration system, every template engine, every "just some YAML" tool is secretly a programming language. The question isn't whether it has language-like properties — it does. The question is whether the implementors have treated it as one: with a specification, with a compositional semantics, with systematic testing of the language's properties rather than just its outputs.

---

## 1. You Built a Programming Language. Four of Them, Actually.

iidy's preprocessing layer is a stack of four distinct languages:

```
┌─────────────────────────────────────────────────────┐
│           iidy Preprocessing Tags (22 forms)        │
│  !$if, !$let, !$map, !$merge, !$concat, !$expand...│
│  Pure tree-walk interpreter, strict CBV, let* scope │
├────────────────┬────────────────────────────────────┤
│  Handlebars    │         JMESPath                   │
│  {{expr}}      │     path.query[*].filter           │
│  22 helpers    │     12 expression forms             │
│  blocks: each, │     Partial RFC impl                │
│  if, unless,   │     No built-in functions           │
│  with          │                                     │
├────────────────┴────────────────────────────────────┤
│       JSON Schema Draft 7 (subset validator)         │
│        The type system for custom resources          │
└─────────────────────────────────────────────────────┘
```

Each has its own parser, its own evaluator, its own value representation, and its own error types. They interact through well-defined boundaries — but the interaction itself has no specification.

This is not a criticism of the implementation. It's a diagnosis: **you are maintaining four language implementations and treating them as application code.**

---

## 2. There Is No Specification

The specification for iidy's preprocessing semantics is the Rust implementation. There is an 858-line informal reference manual (`yaml-preprocessing.md`) that describes features by example. There are 98 snapshot files that define correct output. There is no:

- **Formal grammar.** The 22 tag forms have structural requirements (mapping, sequence, scalar) enforced by the parser, but the grammar is implicit in case branches — not in a document, not in BNF, not in a parser generator.

- **Denotational semantics.** What does `!$map` _mean_? We know what it _does_ — we can read `resolveMapItems` in `Resolver.hs`. But there's no statement of its semantics independent of the implementation. If someone wanted to write a third implementation (in Python, say), they'd have to read Haskell or Rust source code.

- **Interaction specification.** How do the four languages compose? When does handlebars interpolation happen relative to `!$let` binding? When is JMESPath evaluated relative to `!$map` iteration? The answer is in the resolver's evaluation order, but it's not documented.

For a tool that processes CloudFormation templates — infrastructure that controls real AWS resources — this is a significant gap. A user writing `!$map` over a `!$let` binding that contains `{{handlebars}}` referencing a JMESPath query needs to understand the evaluation order. Currently they must either: read the source, or try it and see.

---

## 3. The Evaluation Model Deserves a Name

The resolver (`Resolver.hs`) implements a **strict, call-by-value, lexically scoped, first-order, pure functional interpreter** over a tree-structured AST. Let me name the key semantic properties:

### Evaluation Order: Strict Left-to-Right

Every sub-expression is fully evaluated before the enclosing expression. In `!$map`, the `items` list is resolved before any template instantiation begins. In `!$if`, the `test` expression is resolved before choosing a branch (the unselected branch is _not_ evaluated — so this is strict in the test but lazy in the branches).

```haskell
resolveIf ctx meta (IfTag testAst thenAst elseAst) = do
  testVal <- resolveAst ctx testAst        -- strict in test
  if oIsTruthy testVal
    then resolveAst ctx thenAst            -- then-branch only
    else case elseAst of
      Just e  -> resolveAst ctx e          -- else-branch only
      Nothing -> pure ONull
```

This makes `!$if` a _special form_, not a function — it doesn't evaluate all its arguments. In a PL semantics, this distinction matters.

### Scoping: Flat Map, let\*, No Closures

Variables live in `Map Text OValue`. `!$let` uses sequential binding (`let*`):

```haskell
resolveLet ctx _meta (LetTag bindings expr) = do
  newCtx <- foldBindings ctx bindings
  resolveAst newCtx expr
  where
    foldBindings c ((name, ast):rest) = do
      val <- resolveAst c ast               -- eval in current env
      foldBindings (withVariable name val c) rest  -- extend for next binding
```

Each binding sees all previous bindings but not subsequent ones. There are no closures — `!$map`'s template cannot capture a function, only a value. This makes the language **first-order**: values are data, never code.

### Sub-Language Interaction: Implicit Phase Ordering

The four languages interact through an implicit evaluation pipeline:

1. **Parse time:** Strings containing `{{` become `AstTemplatedString`. All others become `AstPlainString`.
2. **Resolution time (per node):**
   - If `AstTemplatedString`: Handlebars interpolation runs first, producing a `Text`. The result is checked for further `!$` references but is _not_ re-parsed as YAML.
   - If `!$ path jmespath:expr`: The variable is looked up, converted to aeson `Value`, then JMESPath evaluates the expression, then the result is converted back to `OValue`.
   - If `!$expand`: The template body is _re-parsed_ as YAML and _re-resolved_ with the provided params as variables. This is the only place where evaluation triggers parsing.
3. **Custom resource expansion** happens during resolution when a resource's `Type` matches a `$defs` template.

This ordering means:
- Handlebars in `!$let` bindings is interpolated when the binding is evaluated (not when it's defined).
- JMESPath runs after variable lookup but before the result is used in enclosing expressions.
- `!$expand` is a form of _eval_ — it takes a string, parses it, and evaluates it.

None of this is specified. It's discovered by reading the resolver.

---

## 4. Bracket Expansion Is Dynamic Scoping in Disguise

```haskell
expandBrackets :: Text -> TagContext -> Text
-- Turns: config[environment].database[region]
-- Into:  config.production.database.us-east-1
```

Bracket notation in `!$` variable paths dynamically resolves variable names _within_ the path string. `config[env]` looks up the variable `env` in the current scope, substitutes its string value into the path, then looks up the resulting path.

This is essentially **dynamic name construction** — the variable being accessed depends on runtime values. It's the same mechanism as PHP's variable variables (`$$name`), Python's `getattr(obj, name)`, or Lisp's `(eval (intern name))`.

The resolver limits bracket expansion to 10 levels of indirection (`Resolver.hs:484`). Without this limit, bracket expansion would be unbounded. With it, it's bounded but the depth-10 limit is arbitrary and undocumented in user-facing docs.

From a PL perspective, this is the most dangerous feature in the language. It makes static analysis impossible — you can't know what variable a reference resolves to without evaluating the entire program.

---

## 5. Custom Resources Are a Module System with Type Checking

The `$defs` / `!$expand` mechanism is genuinely a parameterized module system:

- `$defs` registers a named template with a parameter schema (the "type signature").
- `!$expand` instantiates a template with arguments (the "module application").
- `validateParams` checks the arguments against the schema (the "type checker").
- `RefRewriting` renames internal references (a form of "capture-avoiding substitution").

This is the most language-like feature and the one most deserving of formal treatment. The expansion semantics involve:

1. **Parsing** the template body (from stored text, not a pre-parsed AST).
2. **Evaluation** with params merged into the environment.
3. **Post-processing** — overrides application, reference rewriting, global extraction.

The re-parsing step is significant: it means `!$expand` is an `eval`. The template body is a _string_ that gets parsed and evaluated at expansion time. This means the template body can contain any iidy preprocessing tag, and its semantics depend on the full resolver. The expansion is not a simple substitution — it's a full re-interpretation.

The `RefRewriting.hs` module implements capture-avoiding substitution for CloudFormation references (`!Ref`, `Fn::GetAtt`, `Fn::Sub ${...}`). It tracks "global" references (those marked with `$global: true`) and avoids rewriting them. This is directly analogous to the capture-avoiding substitution in lambda calculus — and about as tricky to get right.

**But: there is no cycle detection for `!$expand`.** Import cycle detection exists for `$imports` (via `ImportStack`), but `!$expand` can recurse without bound. A custom resource that expands to another custom resource that expands to the first would loop forever. The only protection is the bracket expansion depth limit (10), which is irrelevant here.

---

## 6. Testing: Specification by Example, Not by Law

The test suite has 958 tests. The coverage is impressive. But from a PL testing perspective, the strategy has a characteristic shape:

### What's Present: Operational Correctness

- **37 render snapshots** compared against the Rust oracle. This is differential testing — the gold standard for "does our interpreter match theirs?"
- **49 error snapshots** compared against Rust's error output.
- **35 fixture input/output pairs** that serve as executable specifications.
- **158 unit tests** in `ResolverTest.hs` covering all 22 tag forms.
- **42 property tests** covering format invariants and round-trip laws.

### What's Missing: Semantic Laws

No property tests encode the _algebraic laws_ of the preprocessing language. For example:

**Associativity of `!$merge`:** If `!$merge` merges objects, is `merge(merge(a,b),c) == merge(a,merge(b,c))`? CloudFormation templates depend on this if users compose merges. There's no test.

**Commutativity or non-commutativity of `!$merge`:** Is `merge(a,b) == merge(b,a)`? (Almost certainly not — later values override earlier ones.) This _non_-commutativity is an important semantic property that should be tested.

**Distributivity of `!$map` over `!$concat`:** Does `map(f, concat(xs, ys)) == concat(map(f, xs), map(f, ys))`? This is a free theorem for any lawful functor. Does iidy's `!$map` satisfy it?

**Equivalence of `!$` and `{{...}}`:** The Rust test suite has an explicit equivalence test: `!$ var` and `{{var}}` produce identical results on scalars. The Haskell suite has a fixture for this (`include-equivalence.yaml`) but no property test. A property test would universally quantify over variable values and verify the equivalence, catching edge cases that a single fixture can't.

**Idempotency of resolution:** If you resolve a fully-resolved document again (no `!$` tags, no `{{...}}`), do you get the same result? This should be trivially true, but it's not tested.

**Preservation of non-preprocessing content:** Tags without `!$` prefixes (`!Ref`, `!Sub`, etc.) should pass through resolution unchanged. This is tested implicitly by fixtures but not as a universal property.

### What This Means

The testing strategy is **implementation-tested, not specification-tested**. It verifies that the interpreter produces correct outputs for specific inputs, but doesn't verify that the interpreter satisfies the algebraic properties that users implicitly rely on.

For a user who writes `!$merge` inside `!$map` inside `!$let`, the question isn't "does this specific program produce the right output?" — it's "can I rely on merge being right-biased? on map preserving order? on let being sequential?" These are semantic guarantees, and they deserve to be tested as properties.

---

## 7. The Truthiness Problem

The `oIsTruthy` function defines when a value is "truthy":

```haskell
oIsTruthy :: OValue -> Bool
oIsTruthy ONull           = False
oIsTruthy (OBool b)       = b
oIsTruthy (OString s)     = not (T.null s)
oIsTruthy (ONumber _)     = True     -- all numbers, including 0
oIsTruthy (OArray xs)     = not (null xs)
oIsTruthy (OObject kvs)   = not (null kvs)
```

This is JavaScript-like truthiness. `0` is truthy, `""` is falsy, `[]` is falsy. These rules are shared across the preprocessor (`!$if`), Handlebars (`{{#if}}`), and JMESPath (filter expressions).

But: **this truthiness table is not documented anywhere for users.** A user writing `!$if test: !$ count` needs to know that `0` is truthy. If `count` is `0`, the `then` branch fires — which is almost certainly not what the user intended.

Every language has a truthiness table. The responsible thing is to document it prominently, or better, to avoid implicit truthiness conversions entirely and require explicit comparisons (`!$eq` with `0`).

---

## 8. JMESPath: An Underspecified Subset

The JMESPath implementation is explicitly a custom partial implementation. The `JExpr` AST has 15 forms. The full JMESPath specification defines:

- **Built-in functions:** `length()`, `keys()`, `values()`, `sort()`, `contains()`, `type()`, `to_string()`, `to_number()`, `abs()`, `ceil()`, `floor()`, `min()`, `max()`, `sum()`, `avg()`, `join()`, `reverse()`, `sort_by()`, `min_by()`, `max_by()`, `starts_with()`, `ends_with()`, `not_null()`, `merge()`, `map()`. **None are implemented.**
- **Object wildcard:** `.*` — **not in the AST.**
- **Slice expressions:** `[0:5]`, `[::2]` — mentioned in the module header but **no `JSlice` constructor exists in `JExpr`.**

The Rust implementation delegates to the `jmespath` crate (full spec compliance). This means the Rust binary accepts JMESPath expressions that the Haskell port silently fails on or parses incorrectly. The differential tests only cover expressions that appear in fixtures — if a user writes `length(@)` or `[0:5]`, the Haskell port will fail where Rust succeeds.

**This divergence is not documented in `DIVERGENCES.md`.**

From a PL perspective, implementing a subset of a specified language without documenting the subset is a specification-compliance bug. Users reading the JMESPath docs at `jmespath.org` will write expressions that don't work, and the error messages won't say "unsupported feature" — they'll say "parse error."

---

## 9. Error Reporting: Good Infrastructure, Missing Content Tests

The error display pipeline (`Errors/Display.hs`) produces clang/rustc-style diagnostics:

```
Type error: expected sequence, found string @ file.yaml:42:5 (errno: ERR_5001)
  -> data type mismatch

  41 |   key: value
  42 |   items: not-a-list
       ^^^^^ expected sequence

   For more info: iidy explain ERR_5001
```

This is genuinely excellent. Source locations are threaded through every AST node. Error IDs are structured (9 categories, 55 codes). The `iidy explain` command provides detailed documentation for each error code.

But: **the error fixture tests only verify that an error _occurs_, not what it _says_.** The error message content is tested only by the out-of-band snapshot comparison script. `cabal test` doesn't catch error message regressions.

A PL researcher would say: the error messages are part of the language's user interface. They should be specified and tested with the same rigor as correct outputs. If `ERR_2001` says "variable 'foo' not found" and lists available variables, that list should be tested — it's a semantic property (what variables are in scope at this point).

---

## 10. What Would a Language-First Approach Look Like?

1. **Write a specification.** Not the informal reference manual — a precise specification of each tag's semantics, ideally in the style of PLT Redex or a denotational semantics. Even a careful English specification would be a major improvement. The specification should cover:
   - Evaluation order (strict, left-to-right, with `!$if` as a special form)
   - Scoping rules (`let*`, flat map, bracket expansion)
   - Sub-language interaction (when handlebars runs relative to resolution)
   - Truthiness table
   - Custom resource expansion semantics (re-parsing, ref rewriting, global extraction)

2. **Test semantic laws, not just examples.** Add property tests for:
   - `!$merge` right-bias: `merge([a, b])` has `b`'s keys overriding `a`'s
   - `!$map` preserves length: `length(map(f, xs)) == length(xs)` (when no filter)
   - `!$let` scoping: inner bindings shadow outer, not vice versa
   - `!$concat` associativity: `concat([concat([a,b]),c]) == concat([a,concat([b,c])])`
   - `!$` / `{{}}` equivalence on all value types

3. **Document the JMESPath subset.** Either implement the full spec (functions, slices, object wildcard) or explicitly document what's supported and give clear errors for unsupported features.

4. **Add `!$expand` cycle detection.** The import system has it. The expansion system doesn't. This is a latent infinite loop.

5. **Test error message content in `cabal test`.** Move the snapshot comparison into the test suite so error message regressions are caught by CI, not by manual script runs.

---

## Verdict

The implementation quality is high. The interpreter is pure, the phases are cleanly separated, source locations are preserved, the error messages are modern. The property tests cover more algebraic ground than most application codebases.

But the project treats its language implementation as _application code_ rather than as a _language implementation_. The difference is: application code is tested against requirements; language implementations are tested against specifications. Requirements say "this input produces this output." Specifications say "these are the semantic laws, and all programs satisfy them."

iidy has requirements testing (fixtures, snapshots, differential tests). It doesn't have specification testing. For a tool that generates AWS infrastructure from a Turing-adjacent DSL, that gap matters.

As I'd tell my students: **if you find yourself writing an evaluator for a tree-structured AST with variable binding, conditionals, iteration, and a module system — you've built a programming language. Own it.**
