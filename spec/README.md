# iidy Formal Semantics (PLT Redex)

Machine-readable, executable formal grammar and operational semantics for
iidy's preprocessing language, written in [PLT Redex](https://redex.racket-lang.org/).

## What This Gives You

- **`define-language`** — machine-readable grammar for the value domain and all 22 preprocessing tags
- **`define-judgment-form`** — big-step evaluation rules (⟨e, σ⟩ ⇓ v)
- **`define-metafunction`** — environment operations, merge, truthiness predicates
- **`test-judgment-holds`** / **`rackunit`** — runnable test cases that verify the spec
- **`redex-check`** — QuickCheck-style property tests (planned, Session 4)

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
123 success(es) 0 failure(s) 0 error(s) 123 test(s) run
```

## File Structure

```
spec/
├── flake.nix                    Nix dev shell (Racket)
├── .envrc                       direnv integration
├── README.md                    This file
├── lang/
│   ├── core.rkt                 Iidy-Core: value domain (null, bool, num, str, arr, obj)
│   └── preprocessing.rkt        Iidy-Preprocess: all 22 tag expression forms
├── semantics/
│   ├── truthiness.rkt           Three truthiness variants (iidy, Handlebars, JMESPath)
│   ├── env.rkt                  Environment: lookup, extend, path resolution
│   ├── merge.rkt                Merge, concat, from-pairs, val->text
│   └── eval.rkt                 Big-step evaluation judgment + iteration helpers
└── tests/
    ├── run-all.rkt              Master test runner
    ├── grammar-tests.rkt        Grammar well-formedness
    ├── truthiness-tests.rkt     Truthiness predicate tests
    └── eval-tests.rkt           Per-tag evaluation tests
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
| `!$parseYaml`    | `(parse-yaml e)`                 | Serialization      |
| `!$toJsonString` | `(to-json e)`                    | Serialization      |
| `!$parseJson`    | `(parse-json e)`                 | Serialization      |
| `!$escape`       | `(escape e)`                     | Escape             |
| `!$expand`       | `(expand e e)`                   | Template expansion |

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

## Planned Extensions

- **Session 2**: Map/iteration tests, property tests
- **Session 3**: Handlebars sub-language grammar + evaluation, JMESPath sub-language
- **Session 4**: `!$expand` with cycle detection, `redex-check` property tests

## Reference

The formal semantics are derived from the Haskell implementation:

| Haskell Module                        | Informs                |
|---------------------------------------|------------------------|
| `Iidy.Yaml.Ast`                       | Grammar productions    |
| `Iidy.Yaml.OValue`                    | Value domain           |
| `Iidy.Yaml.Resolution.Resolver`       | Evaluation rules       |
| `Iidy.Yaml.Resolution.Context`        | Environment operations |
| `Iidy.Yaml.Handlebars.Engine`         | Handlebars evaluation  |
| `Iidy.Yaml.JMESPath`                  | JMESPath evaluation    |
