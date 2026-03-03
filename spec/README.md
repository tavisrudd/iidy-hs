# iidy Formal Semantics (PLT Redex)

Machine-readable, executable formal grammar and operational semantics for
iidy's preprocessing language, written in [PLT Redex](https://redex.racket-lang.org/).

Addresses Krishnamurthi review finding #2: "There is no specification."

*Last updated: 2026-03-03. 410 tests (371 unit + 39 property), 20 modules.*

## What This Gives You

- **`define-language`** — machine-readable grammars for all 5 language layers
- **`define-judgment-form`** — big-step evaluation rules (⟨e, σ⟩ ⇓ v)
- **`define-metafunction`** — environment operations, merge, rendering, query evaluation
- **`rackunit`** — 370+ unit tests verifying the spec
- **`redex-check`** — 40 QuickCheck-style property tests (200 random attempts each)

## Prerequisites

Enter the nix dev shell:

```bash
cd spec/
nix develop    # or: direnv allow
```

This provides Racket 9.x with the `redex` package.

## Running Tests

```bash
cd spec/
racket tests/run-all.rkt
```

Expected output:
```
410 success(es) 0 failure(s) 0 error(s) 410 test(s) run
```

## File Structure

```
spec/
├── flake.nix                    Nix dev shell (Racket)
├── .envrc                       direnv integration
├── README.md                    This file
├── lang/
│   ├── core.rkt                 Iidy-Core: value domain (null, bool, num, str, arr, obj)
│   ├── preprocessing.rkt        Iidy-Preprocess: all 22 tag expression forms
│   ├── handlebars.rkt           Iidy-Handlebars: template AST (parts, expressions, blocks)
│   └── jmespath.rkt             Iidy-JMESPath: query AST (14 expression forms)
├── semantics/
│   ├── truthiness.rkt           Three truthiness variants (iidy, Handlebars, JMESPath)
│   ├── env.rkt                  Environment: lookup, extend, path resolution
│   ├── merge.rkt                Merge, concat, from-pairs, val->text
│   ├── eval.rkt                 Big-step evaluation judgment + integration rules
│   ├── handlebars-eval.rkt      Template rendering (block helpers, path lookup, helpers)
│   ├── jmespath-eval.rkt        JMESPath query evaluation (projections, filters, etc.)
│   └── bracket-expansion.rkt    Dynamic path segment resolution
└── tests/
    ├── run-all.rkt              Master test runner
    ├── grammar-tests.rkt        Grammar well-formedness
    ├── truthiness-tests.rkt     Truthiness predicate tests
    ├── env-tests.rkt            Environment operation tests
    ├── merge-tests.rkt          Merge/concat/from-pairs tests
    ├── eval-tests.rkt           Per-tag evaluation + integration tests
    ├── properties.rkt           redex-check property tests (39 properties)
    ├── handlebars-tests.rkt     Handlebars rendering tests
    ├── jmespath-tests.rkt       JMESPath evaluation tests
    └── bracket-expansion-tests.rkt  Bracket expansion tests
```

## Language Layers

### Iidy-Core (`lang/core.rkt`)

The semantic domain — what iidy expressions evaluate to:

```
v ::= null | (bool b) | (num n) | (str s) | (arr (v ...)) | (obj ((k v) ...))
```

Objects use ordered association lists (insertion order preserved), matching
iidy's `OObject` type. Environment bindings use string keys.

### Iidy-Preprocess (`lang/preprocessing.rkt`)

Extends Iidy-Core with expression forms for all 22 preprocessing tags:

| Tag              | Expression Form                  | Category          |
|------------------|----------------------------------|--------------------|
| `!$`             | `(var path)`                     | Variable lookup    |
| `!$ ? query`     | `(var-q path query)`             | Lookup + dot-query |
| `!$ @ jmespath`  | `(var-j path jmespath)`          | Lookup + JMESPath  |
| `!$if`           | `(if e e e)`                     | Conditional        |
| `!$let`          | `(let ((name e) ...) e)`         | Binding            |
| `!$map`          | `(map e e var-name)`             | Iteration          |
| `!$concat`       | `(concat (e ...))`               | Aggregation        |
| `!$merge`        | `(merge (e ...))`                | Aggregation        |
| `!$eq`           | `(eq e e)`                       | Comparison         |
| `!$not`          | `(not e)`                        | Comparison         |
| `!$split`        | `(split e e)`                    | String ops         |
| `!$join`         | `(join e e)`                     | String ops         |
| `!$concatMap`    | `(concat-map e e var-name)`      | Compound iteration |
| `!$mergeMap`     | `(merge-map e e var-name)`       | Compound iteration |
| `!$mapListToHash`| `(map-list-to-hash e e var-name)`| Compound iteration |
| `!$mapValues`    | `(map-values e e var-name)`      | Compound iteration |
| `!$groupBy`      | `(group-by e e var-name)`        | Compound iteration |
| `!$fromPairs`    | `(from-pairs e)`                 | Construction       |
| `!$toYamlString` | `(to-yaml e)`                    | Serialization      |
| `!$toJsonString` | `(to-json e)`                    | Serialization      |
| `!$escape`       | `(escape e)`                     | Escape             |
| `!$expand`       | `(expand e e)`                   | Template expansion |

### Iidy-Handlebars (`lang/handlebars.rkt`)

Template AST for string interpolation (`{{...}}`):

```
tmpl ::= (tp ...)
tp   ::= (hb-literal s) | (hb-output hx) | (hb-block kind hx tmpl tmpl) | hb-comment
hx   ::= (hb-path (s ...)) | (hb-lit-str s) | (hb-lit-num n) | (hb-lit-bool b)
       | (hb-helper s (hx ...))
kind ::= "if" | "unless" | "each" | "with"
```

### Iidy-JMESPath (`lang/jmespath.rkt`)

Query expression AST (iidy's implemented subset):

```
jx ::= (jfield s) | (jindex i) | (jsub jx jx) | jwildcard | (jproj jx jx)
     | (jflatten jx) | (jfilter jx jx) | (jmulti-hash ((s jx) ...))
     | (jmulti-list (jx ...)) | (jlit v) | (jpipe jx jx) | jidentity
     | (jcmp op jx jx) | (jnot jx)
```

### Iidy-BracketExpansion (`semantics/bracket-expansion.rkt`)

Dynamic path segment resolution: `config[env].host` → `config.production.host`

```
bpath    ::= (bsegment ...)
bsegment ::= string | (bracket-ref string)
```

## Key Semantic Distinctions

### Truthiness: Three Variants

iidy has three distinct truthiness definitions:

| Value          | iidy (`truthy`) | Handlebars (`truthy/hbs`) | JMESPath (`truthy/jmespath`) |
|----------------|-----------------|---------------------------|-------------------------------|
| `null`         | falsy           | falsy                     | falsy                         |
| `(bool #f)`    | falsy           | falsy                     | falsy                         |
| `(str "")`     | falsy           | falsy                     | falsy                         |
| `(num 0)`      | **falsy**       | **truthy**                | **truthy**                    |
| `(arr ())`     | falsy           | falsy                     | falsy                         |
| `(obj ())`     | falsy           | falsy                     | falsy                         |
| everything else| truthy          | truthy                    | truthy                        |

The key difference: **iidy treats 0 as falsy** while Handlebars and JMESPath
(following their respective specs) treat all numbers as truthy.

### Merge Semantics

`merge-objs` is **shallow** and **right-biased**: overlay keys win on collision,
base key order is preserved, new overlay keys are appended.

### Model Boundaries

Some rules are formally specified but not executable in the Redex model:

| Rule        | Why not executable                    | Tested via                |
|-------------|---------------------------------------|---------------------------|
| E-Var-J     | Requires JMESPath string parser       | jmespath-tests.rkt        |
| E-ParseYaml | Requires YAML string parser           | Round-trip property spec   |
| E-ParseJson | Requires JSON string parser           | Round-trip property spec   |
| E-Expand    | Requires template registry Σ          | Formal spec in comments   |

### Sub-Language Composition

The four sub-languages (Iidy-Preprocess, Iidy-Handlebars, Iidy-JMESPath,
and bracket expansion) each extend Iidy-Core independently. They are fully
specified and tested in their own modules, but **they cannot compose within
the eval judgment** because their non-terminals are not in each other's
scope. Concretely:

- **E-Tpl** (template strings) uses a simple regex-based renderer
  (`simple-tpl-render`) that handles `{{path.to.var}}` interpolation.
  The full Handlebars renderer in `handlebars-eval.rkt` — with block
  helpers (`{{#if}}`, `{{#each}}`), helper functions, and literals — is
  specified and tested separately but cannot be called from E-Tpl.

- **E-Var-J** (JMESPath queries) is specified as a comment only. The
  JMESPath evaluator in `jmespath-eval.rkt` is fully functional (14
  expression forms, 110 tests), but its `jx` non-terminals are not
  available in the Iidy-Preprocess grammar where eval is defined.

- **Bracket expansion** (`bracket-expansion.rkt`) is tested in isolation.
  It cannot be composed with variable resolution in the eval judgment.

A union language (`Iidy-Full`) merging all sub-language grammars into a
single `define-extended-language` would resolve this, allowing E-Tpl to
dispatch to `render-template` and E-Var-J to call `jeval`. This refactor
was evaluated and deferred: the sub-languages are individually validated
(~210 tests) and the composition gap does not affect any correctness
properties of the individual semantics.

**In the Haskell implementation, all sub-languages compose naturally**
because they share the same AST type. This spec models each sub-language's
semantics faithfully; the composition gap is an artifact of the Redex
formalization, not of iidy's design.

## Reference

The formal semantics are derived from the Haskell implementation:

| Haskell Module                        | Informs                |
|---------------------------------------|------------------------|
| `Iidy.Yaml.Ast`                       | Grammar productions    |
| `Iidy.Yaml.OValue`                    | Value domain           |
| `Iidy.Yaml.Resolution.Resolver`       | Evaluation rules       |
| `Iidy.Yaml.Resolution.Context`        | Environment operations |
| `Iidy.Yaml.Handlebars.Engine`         | Handlebars evaluation  |
| `Iidy.Yaml.Handlebars.Helpers`        | Helper function set    |
| `Iidy.Yaml.JMESPath`                  | JMESPath evaluation    |
