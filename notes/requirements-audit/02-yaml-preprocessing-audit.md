# Audit: 02-yaml-preprocessing.md

Audited 2026-03-05 against Haskell codebase (Engine.hs, Resolver.hs, Context.hs, Handlebars/Engine.hs, Handlebars/Helpers.hs, OValue.hs, Ast.hs, Parser.hs, JMESPath.hs).

## Accuracy Issues

### 1. Zero truthiness (US-02-003)
**Requirement says:** "zero is truthy (not falsy)"
**Code (OValue.hs:92):** `ONumber n -> n /= 0` -- zero IS falsy.
**Verdict:** Requirement was WRONG. Code matches Rust (`n != 0.0`). The comment in OValue.hs explicitly says "zero is FALSY here (matching Rust iidy's is_truthy: n != 0.0)".
**Fix:** Update requirement to say zero is falsy.

### 2. Handlebars helper count (US-02-007)
**Requirement says:** "All 28 helpers"
**Code (Helpers.hs:38-71):** 25 entries in `defaultHelpers` map. Counting unique functions (aliases share implementations): 8 case + 6 manipulation + 3 encoding + 4 serialization (toJson, toJsonPretty, toYaml unique; 3 deprecated aliases) + 1 lookup + 1 eq = 23 unique + 3 aliases = 26 entries. Wait -- actual count from code:
- toLowerCase, toUpperCase, titleize, camelCase, pascalCase, snakeCase, kebabCase, capitalize (8)
- trim, replace, substring, length, pad, concat (6)
- base64, urlEncode, sha256 (3)
- toJson, tojson, toJsonPretty, tojsonPretty, toYaml, toyaml (6)
- lookup (1)
- eq (1)
Total: 25 entries in the Map.

The requirement table lists 25 entries too (8 + 6 + 3 + 6 + 1 + 1 = 25), but the heading says "28". The encoding section header says "Encoding (5):" but only lists 3 helpers (base64, urlEncode, sha256). The "5" is wrong.
**Fix:** Change heading to "All 25 helpers" and fix "Encoding (5):" to "Encoding (3):".

### 3. Escaped Handlebars syntax
**Requirement says:** "`\{{` escapes a literal `{{`"
**Code (Handlebars/Engine.hs):** No backslash escape handling exists. The parser uses `T.breakOn "{{"` which does not handle `\{{`.
**Verdict:** Feature not implemented. Remove from spec or mark as not-implemented divergence.
**Fix:** Remove the `\{{` escape claim since neither the code nor Rust iidy implements it.

### 4. Three truthiness contexts
The requirement only documents one truthiness rule but there are actually THREE distinct truthiness functions:
- `OValue.oIsTruthy`: zero is falsy (used by !$if, !$not, !$map filter)
- `Handlebars.Engine.isTruthy`: zero is truthy (Handlebars spec)
- `JMESPath.isTruthy`: zero is truthy (JMESPath spec)
**Fix:** Document that Handlebars `{{#if}}` and JMESPath filters use different truthiness than `!$if`.

## Missing from Requirements

### 5. Tag count is 22, not 21
Parser.hs shows 22 distinct tags (counting `!$include` as alias for `!$`, and `!$string` as alias for `!$toYamlString`):
`!$`, `!$include`, `!$if`, `!$map`, `!$merge`, `!$concat`, `!$let`, `!$eq`, `!$not`, `!$split`, `!$join`, `!$concatMap`, `!$mergeMap`, `!$mapListToHash`, `!$mapValues`, `!$groupBy`, `!$fromPairs`, `!$toYamlString`, `!$string`, `!$parseYaml`, `!$toJsonString`, `!$parseJson`, `!$escape`, `!$expand`
- `!$expand` is not documented in 02-yaml-preprocessing.md (it's in 04-custom-resources.md)
- `!$include` alias for `!$` not mentioned
- `!$string` alias for `!$toYamlString` is mentioned but only in passing

### 6. Phase 1 scoping details not specified as pseudocode
The two-phase pipeline description is prose-only. Complex sequencing logic (defs -> imports -> recursive preprocessing) should be pseudocode.

### 7. Resolution context type not shown
`TagContext` carries: variables (Map Text OValue), inputUri, customTemplateDefs, activeExpansions. The scoping mechanism (`withBindings` uses `Map.union bindings existing` -- new bindings shadow) is not documented.

### 8. OValue type not documented
The ordered value representation is critical to understanding key-order preservation but the type is never shown.

### 9. ResolveError structure not documented
The structured error type (ResolveErrorKind with 8+ variants) carries semantic information that downstream code uses, but the requirement just lists error codes without showing the error data model.

### 10. 20 CloudFormation tag pass-throughs not enumerated
The requirement mentions "CloudFormation tag nodes" but never lists the 20 supported CFN tags (Ref, Sub, GetAtt, Join, Select, Split, Base64, GetAZs, ImportValue, FindInMap, Cidr, Length, ToJsonString, Transform, ForEach, If, Equals, And, Or, Not).

### 11. Import manifest record structure
The manifest records (ImportRecord with irKey, irFrom, irImported, irSha256Digest) are mentioned in prose but never shown as a type.

### 12. YAML 1.1 compat conversion is case-SENSITIVE membership
The requirement says "all case variants" but the code uses exact membership in 18 strings (true/True/TRUE, false/False/FALSE, etc.). `tRue` does NOT convert.

## Completeness Assessment

| Section                  | Status           | Notes                                                    |
|--------------------------|------------------|----------------------------------------------------------|
| Two-Phase Pipeline       | NEEDS_PSEUDOCODE | Prose is correct but complex ordering needs pseudocode   |
| Variable Scope           | NEEDS_TYPES      | Missing TagContext type and shadowing semantics           |
| Key Order Preservation   | NEEDS_TYPES      | Missing OValue type declaration                          |
| US-02-001: $defs/$imports| COMPLETE         | Accurate                                                 |
| US-02-002: Variable !$   | COMPLETE         | Missing !$include alias mention                          |
| US-02-003: Conditionals  | INACCURATE       | Zero truthiness wrong; three truthiness contexts missing |
| US-02-004: Collections   | COMPLETE         | Accurate                                                 |
| US-02-005: String tags   | COMPLETE         | Accurate                                                 |
| US-02-006: !$let/!$escape| COMPLETE         | Accurate                                                 |
| US-02-007: Handlebars    | INACCURATE       | Count wrong (25 not 28); encoding count wrong; \\{{ claim false |
| US-02-008: YAML 1.1      | COMPLETE         | Minor: case-sensitive membership detail missing          |
| US-02-009: Error tracking| NEEDS_TYPES      | Missing ResolveErrorKind type                            |
