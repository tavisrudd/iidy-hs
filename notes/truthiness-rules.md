# Truthiness Rules for `oIsTruthy`

## Summary

The `oIsTruthy` function (`src/Iidy/Yaml/OValue.hs`) determines whether an
`OValue` is truthy or falsy. It is used by the YAML preprocessing tags `!$if`,
`!$not`, `!$map` (filter), `!$concatMap` (filter), and `!$mapListToHash`
(filter). The rules match the Rust iidy implementation (`Resolver::is_truthy`
in `src/yaml/resolution/resolver.rs`) exactly.

## Truthiness Table

| OValue type  | Truthy                        | Falsy                     |
|--------------|-------------------------------|---------------------------|
| `ONull`      | never                         | always                    |
| `OBool`      | `True`                        | `False`                   |
| `OString`    | non-empty (`"hello"`)         | empty (`""`)              |
| `ONumber`    | non-zero (`42`, `-1`, `0.5`)  | zero (`0`, `0.0`)         |
| `OArray`     | non-empty (`[1]`)             | empty (`[]`)              |
| `OObject`    | non-empty (`{a: 1}`)         | empty (`{}`)              |

## Where It Is Used

| Tag              | How truthiness is used                                          |
|------------------|-----------------------------------------------------------------|
| `!$if`           | Evaluates `test`; if truthy, returns `then`; otherwise `else`   |
| `!$not`          | Returns `Bool (not (oIsTruthy val))`                            |
| `!$map`          | Optional `filter` expression; items where filter is falsy are dropped |
| `!$concatMap`    | Same filter behavior as `!$map`                                 |
| `!$mapListToHash`| Same filter behavior as `!$map`                                 |

Note: `!$mergeMap` does **not** support a `filter` field; it passes `Nothing`
for the filter argument in both Rust and Haskell.

## Non-Obvious Cases

- **Zero is falsy.** `ONumber 0` evaluates to `False`. This was a bug prior to
  Session 46 -- a property test discovered that `oIsTruthy (ONumber 0)` returned
  `True`, diverging from Rust. Now fixed.
- **Empty string is falsy.** `OString ""` evaluates to `False`.
- **Empty collections are falsy.** Both `OArray []` and `OObject []` are falsy.
- **All non-zero numbers are truthy.** Negative numbers, fractions, very large
  numbers -- all truthy as long as they are not exactly zero.

## Comparison with Other Languages

| Value        | iidy `oIsTruthy` | Python  | JavaScript | Ruby    |
|--------------|------------------|---------|------------|---------|
| `null`/`nil` | falsy            | falsy   | falsy      | falsy   |
| `false`      | falsy            | falsy   | falsy      | falsy   |
| `true`       | truthy           | truthy  | truthy     | truthy  |
| `0`          | falsy            | falsy   | falsy      | truthy  |
| `""`         | falsy            | falsy   | falsy      | truthy  |
| `[]`         | falsy            | falsy   | truthy     | truthy  |
| `{}`         | falsy            | falsy   | truthy     | truthy  |
| `42`         | truthy           | truthy  | truthy     | truthy  |
| `"hello"`    | truthy           | truthy  | truthy     | truthy  |

iidy's truthiness rules are closest to Python's. The only difference from
JavaScript is that iidy treats empty arrays and objects as falsy. Ruby is the
most permissive -- only `nil` and `false` are falsy.

## Three Truthiness Functions in the Codebase

The codebase contains three separate truthiness implementations. They differ
on how they treat the number zero:

| Function                        | Module                          | `0` is | Spec followed      |
|---------------------------------|---------------------------------|--------|---------------------|
| `oIsTruthy`                     | `Iidy.Yaml.OValue`             | falsy  | Rust iidy           |
| `isTruthy` (Handlebars)         | `Iidy.Yaml.Handlebars.Engine`  | truthy | Handlebars.js spec  |
| `isTruthy` (JMESPath)           | `Iidy.Yaml.JMESPath`           | truthy | JMESPath spec       |

This is intentional. Handlebars and JMESPath each follow their own specification
where all numbers (including zero) are truthy. The preprocessing tags (`!$if`,
`!$not`, `!$map` filter) use `oIsTruthy`, which follows the Rust iidy behavior
where zero is falsy.

## User-Facing Documentation

The file `docs/yaml-preprocessing.md` documents `!$if`, `!$not`, and collection
tag filters but does not explain which values are considered truthy or falsy.
The word "truthy" appears once (in the `!$if` description) without definition.
A truthiness table similar to the one above would be a useful addition to the
user-facing docs, likely in the `!$if` / `!$eq` / `!$not` section or as a
standalone reference section.
