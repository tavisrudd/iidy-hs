# PRD: YAML Preprocessing

## Overview

The YAML preprocessing system is iidy's core transformation engine. It accepts
a YAML document that may contain special header keys (`$imports`, `$defs`),
custom processing tags (`!$if`, `!$map`, etc.), and Handlebars template
expressions (`{{ }}`), and produces a plain YAML document with all
transformations applied.

The preprocessor is purely functional after the import phase: every operation
is a side-effect-free data transformation. This property makes it safe to use
`iidy render` to preview output without deploying, and makes the preprocessing
pipeline fully testable in isolation.

The system is also used outside CloudFormation. Teams run `iidy render` to
generate Kubernetes manifests, CI configuration, and other YAML-based
artifacts.

## Technical Context

### Two-Phase Pipeline

```pseudocode
preprocess(ast, baseLocation, yaml11Compat):
  -- Phase 1: I/O-bound
  importStack = pushImport(baseLocation, emptyStack)
  (env, templateDefs, manifest) = loadImportsAndDefs(ast, baseLocation, {}, {}, emptyManifest, importStack)

  -- Phase 2: Pure resolution
  ctx = TagContext { variables = env, inputUri = baseLocation, customTemplateDefs = templateDefs }
  resolved = resolveAst(ctx, ast)

  -- Post-pass
  if yaml11Compat:
    resolved = convertYaml11Compat(resolved)

  return PreprocessResult { value = resolved, importRecords = manifest }

loadImportsAndDefs(ast, baseLocation, env, templateDefs, manifest, stack):
  if ast is not a Mapping: return (env, templateDefs, manifest, stack)

  defsAst   = findSection("$defs", ast)
  importsAst = findSection("$imports", ast)

  -- Process $defs first (let* semantics)
  for each (key, valueAst) in defsAst:
    ctx = TagContext { variables = env }
    resolved = resolveAst(ctx, valueAst)
    env = env + { key: resolved }

  -- Process $imports sequentially
  for each (key, locationAst) in importsAst:
    locationText = extractText(locationAst)
    resolvedLoc  = interpolateHandlebars(env, locationText)  -- only if "{{" present
    stack        = pushImport(resolvedLoc, stack)             -- cycle detection
    importData   = loader(resolvedLoc, baseLocation)
    if importData has $params: register as customTemplate(key, importData)
    manifest     = addRecord(key, baseLocation, importData.location, sha256(importData.rawData))
    importedValue = recursivelyPreprocess(importData, env, manifest, stack)
    env          = env + { key: importedValue }
    stack        = popImport(stack)

  return (env, templateDefs, manifest, stack)
```

Phase 1 (I/O-bound): Load `$imports` and resolve `$defs` into an environment map.

1. Parse `$defs` key-value pairs; resolve each value in sequence using the
   environment accumulated so far (let* semantics). Each definition may
   reference earlier definitions in the same `$defs` block.
2. Parse `$imports` key-value pairs; for each, interpolate Handlebars
   expressions in the location string, load the import, and insert the
   imported value into the environment under the given key. If the imported
   document has a `$params` section, register it as a custom resource template
   (see `04-custom-resources.md` for the `$params` parameter definition system).
3. `$defs` is processed before `$imports`. An import location string may
   reference variables defined in `$defs`.

Phase 2 (pure): Build a variable scope from the environment and recursively
resolve all nodes in the document AST.

1. Plain scalars, sequences, and mappings pass through (with special-key
   filtering for `$imports`, `$defs`, `$envValues`, `$params`). The `$envValues`
   key is an internally-injected mapping containing environment metadata
   (region, profile, operation name, environment name) made available during
   stack-args preprocessing; it is not user-authored.
2. Templated string nodes are processed through the Handlebars engine.
3. Preprocessing tag nodes (`!$`) dispatch to per-tag resolvers.
4. CloudFormation tag nodes have their inner content resolved, then pass
   through as tagged YAML.
5. If YAML 1.1 compat mode is requested, a post-pass converts boolean-like
   strings (`yes`, `no`, `on`, `off`, `true`, `false`, all case variants) to
   actual booleans.

### Internal Value Type

The internal value type preserves key insertion order using an association list
rather than an unordered map:

```pseudocode
type OValue =
  | ONull
  | OBool   Bool
  | ONumber Scientific
  | OString Text
  | OArray  [OValue]
  | OObject [(Text, OValue)]   -- insertion-ordered key-value pairs
```

All tag resolution, merge operations, and output emission use this ordered
representation. Standard unordered map types are insufficient: the
implementation must use an ordered association list or equivalent structure so
that key order is maintained throughout the pipeline, producing deterministic
YAML output and preserving CloudFormation resource ordering.

### Variable Scope and Resolution Context

```pseudocode
type TagContext =
  { variables         :: Map Text OValue     -- all variables in scope
  , inputUri          :: Maybe Text          -- source document URI
  , customTemplateDefs :: Map Text TemplateInfo  -- registered custom resource templates
  , activeExpansions  :: Set Text            -- guards against recursive custom resource expansion
  }

withBindings(newBindings, ctx):
  -- new bindings shadow existing ones (Map.union newBindings ctx.variables)
  return ctx { variables = newBindings `union` ctx.variables }

withVariable(name, value, ctx):
  return ctx { variables = insert(name, value, ctx.variables) }
```

The variable scope carries a map of all variables in scope. Binding is purely
substitutive: inserting a new key does not affect other bindings. There are no
closures and no mutable state. Shadowing is first-wins within the same scope
level: outer variables are visible inside `!$let` unless the same name appears
in the `!$let` bindings, in which case the inner binding shadows the outer one.

**Scoping rules by context:**

```pseudocode
-- $defs: sequential (let*), each def sees all prior defs
processDefs(env, defs):
  for each (key, valueAst) in defs:
    ctx = TagContext { variables = env }
    resolved = resolveAst(ctx, valueAst)
    env = insert(key, resolved, env)
  return env

-- $imports: sequential, each import sees all defs + prior imports
processImports(env, imports):
  for each (key, locationAst) in imports:
    resolvedLoc = interpolateHandlebars(env, extractText(locationAst))
    importedValue = loadAndPreprocess(resolvedLoc, env)
    env = insert(key, importedValue, env)
  return env

-- !$let: sequential (let*), inner scope shadows outer
resolveLet(ctx, bindings, inExpr):
  innerCtx = ctx
  for each (name, valueAst) in bindings:
    resolved = resolveAst(innerCtx, valueAst)
    innerCtx = withVariable(name, resolved, innerCtx)
  return resolveAst(innerCtx, inExpr)

-- !$map: loop variable + index injected per iteration
resolveMapIteration(ctx, varName, items, template):
  for i, item in enumerate(items):
    bindings = { varName: item, varName+"Idx": i }
    itemCtx = withBindings(bindings, ctx)  -- shadows outer vars with same names
    yield resolveAst(itemCtx, template)
```

### Path Traversal Semantics

Variable references in `!$` tags support dot paths, bracket expansion, query
selection, and JMESPath expressions. The resolution follows this pipeline:

```pseudocode
resolveVarLookup(ctx, rawPath, query, jmesPathExpr):
  -- Step 1: Bracket expansion (up to 10 levels to prevent infinite loops)
  path = expandBrackets(rawPath, ctx, maxDepth=10)

  -- Step 2: Dot-path traversal
  segments = split(path, ".")
  root = segments[0]
  baseVal = lookupVariable(root, ctx)
  if baseVal is Nothing: error(VariableNotFound, root, availableVars(ctx))
  val = traversePath(segments[1:], baseVal)

  -- Step 3: Query selection (if present)
  if query contains ",":
    -- Multi-key selection: extract named keys from mapping
    keys = map(strip, split(query, ","))
    for each key in keys:
      if key not in val: error(PropertyNotFound, key, availableKeys(val))
    val = OObject([(k, val[k]) | k <- keys])
  else if query is not empty:
    -- Single dot-path traversal into the result
    val = traversePath(split(query, "."), val)

  -- Step 4: JMESPath (if present, mutually exclusive with query)
  if jmesPathExpr is not Nothing:
    val = applyJmesPath(jmesPathExpr, val)

  return val

expandBrackets(path, ctx, depth):
  if depth <= 0 or "[" not in path: return path
  (before, rest) = breakOn("[", path)
  (varName, after) = breakOn("]", drop(1, rest))
  resolved = case lookupVariable(varName, ctx) of
    OString s -> s
    ONumber n -> show(n)
    _         -> varName   -- unresolved: keep literal
  return expandBrackets(before + "." + resolved + drop(1, after), ctx, depth-1)

traversePath(segments, val):
  for each seg in segments:
    case val of
      OObject kvs -> val = lookup(seg, kvs) or error(PropertyNotFound)
      OArray arr  -> val = arr[parseInt(seg)]  or error(IndexOutOfBounds)
      _           -> error(CannotTraverse)
  return val
```

### Truthiness Rules

Three distinct truthiness contexts exist, each with slightly different rules.
**These are not interchangeable.** Using the wrong truthiness in a given context
is a bug.

**Decision table:**

| Value              | Preprocessing (`!$if`, `!$not`, `!$map` filter) | Handlebars (`{{#if}}`, `{{#unless}}`, `{{#with}}`) | JMESPath (`[?filter]`) |
|--------------------|--------------------------------------------------|-----------------------------------------------------|------------------------|
| `null`             | falsy                                            | falsy                                               | falsy                  |
| `false`            | falsy                                            | falsy                                               | falsy                  |
| `true`             | truthy                                           | truthy                                              | truthy                 |
| `""` (empty str)   | falsy                                            | falsy                                               | falsy                  |
| `"hello"` (non-empty) | truthy                                       | truthy                                              | truthy                 |
| `0` (zero)         | **falsy**                                        | **truthy**                                          | **truthy**             |
| `42` (non-zero)    | truthy                                           | truthy                                              | truthy                 |
| `[]` (empty array) | falsy                                            | falsy                                               | falsy                  |
| `[1]` (non-empty)  | truthy                                           | truthy                                              | truthy                 |
| `{}` (empty obj)   | falsy                                            | falsy                                               | falsy                  |
| `{a: 1}` (non-empty) | truthy                                        | truthy                                              | truthy                 |

**Key difference:** Zero is **falsy** in preprocessing but **truthy** in both
Handlebars and JMESPath. This matches the respective upstream specs (Rust iidy
`is_truthy` for preprocessing; Handlebars spec for `{{#if}}`; JMESPath spec for
filters).

**Pseudocode:**

```pseudocode
-- Preprocessing truthiness (OValue.oIsTruthy)
oIsTruthy(value) = case value of
  ONull       -> false
  OBool b     -> b
  OString s   -> s != ""
  ONumber n   -> n != 0         -- zero IS falsy
  OArray a    -> a is not empty
  OObject o   -> o is not empty

-- Handlebars truthiness (Handlebars.Engine.isTruthy)
hbIsTruthy(value) = case value of
  Null        -> false
  Bool b      -> b
  String s    -> s != ""
  Number _    -> true           -- ALL numbers truthy, including zero
  Array a     -> a is not empty
  Object o    -> o is not empty

-- JMESPath truthiness (JMESPath.isTruthy): same as Handlebars
```

### Custom Resource Expansion

When a `$imports` entry has a `$params` section, iidy registers it as a
template. During Phase 2, if the document contains a `Resources` section and
custom templates are registered, any resource whose `Type` matches a registered
template name is expanded. Expanded resources replace the original entry; global
sections emitted by the expansion are merged into the top-level mapping.

### Complete Tag Resolution Reference

The following table summarizes all 24 preprocessing tag names (22 unique tags
plus 2 aliases: `!$include` for `!$` and `!$string` for `!$toYamlString`),
their argument types, and return types:

| Tag                | Alias for        | Argument Shape                                      | Return Type        |
|--------------------|------------------|-----------------------------------------------------|--------------------|
| `!$`               |                  | scalar path or `{path, query?, jmespath?}`          | OValue (any)       |
| `!$include`        | `!$`             | (same as `!$`)                                      | OValue (any)       |
| `!$if`             |                  | `{test, then, else?}`                               | OValue (any)       |
| `!$eq`             |                  | `[left, right]`                                     | OBool              |
| `!$not`            |                  | `[expression]`                                      | OBool              |
| `!$map`            |                  | `{items, template, var?, filter?}`                  | OArray             |
| `!$concatMap`      |                  | `{items, template, var?, filter?}`                  | OArray (flattened)  |
| `!$concat`         |                  | `[source1, source2, ...]`                           | OArray (flattened)  |
| `!$merge`          |                  | `[mapping1, mapping2, ...]`                         | OObject            |
| `!$mergeMap`       |                  | `{items, template, var?}`                           | OObject (merged)    |
| `!$mapListToHash`  |                  | `{items, template, var?, filter?}`                  | OObject            |
| `!$mapValues`      |                  | `{items, template, var?}`                           | OObject            |
| `!$groupBy`        |                  | `{items, key, var?, template?}`                     | OObject of OArrays |
| `!$fromPairs`      |                  | `[[k1,v1], [k2,v2], ...]`                          | OObject            |
| `!$let`            |                  | `{binding1: val1, ..., in: expr}`                   | OValue (any)       |
| `!$escape`         |                  | any YAML value                                      | OValue (raw, no resolution) |
| `!$expand`         |                  | `{template: name, params: {...}}` or `[name, {...}]`| OValue (any)       |
| `!$join`           |                  | `[delimiter, list]`                                 | OString            |
| `!$split`          |                  | `[delimiter, string]`                               | OArray of OString  |
| `!$toYamlString`   |                  | any YAML value                                      | OString (YAML)     |
| `!$string`         | `!$toYamlString` | (same as `!$toYamlString`)                          | OString (YAML)     |
| `!$parseYaml`      |                  | string                                              | OValue (parsed)    |
| `!$toJsonString`   |                  | any YAML value                                      | OString (JSON)     |
| `!$parseJson`      |                  | string                                              | OValue (parsed)    |

The main dispatch function resolves each tag:

```pseudocode
resolveAst(ctx, node):
  case node of
    AstNull              -> ONull
    AstBool b            -> OBool(b)
    AstNumber n          -> ONumber(n)
    AstPlainString s     -> OString(s)
    AstTemplatedString s -> interpolateHandlebars(ctx, s) -> OString
    AstSequence items    -> OArray([resolveAst(ctx, i) | i <- items])
    AstMapping pairs     -> resolveMapping(ctx, pairs) -> OObject (filters special keys)
    AstPreprocessingTag tag -> dispatch to per-tag resolver (see table above)
    AstCloudFormationTag tag -> resolveCfnTag(ctx, tag) -> OObject [("!TagName", resolvedInner)]
    AstUnknownTag name inner -> OObject [(name, resolveAst(ctx, inner))]
    AstImportedDocument node -> resolveAst(ctx, node.content)
```

---

## User Stories

### US-02-001: Preprocess a stack-args.yaml with $defs and $imports

**As a** Developer, **I want to** write a `stack-args.yaml` with `$defs` for
local constants and `$imports` for external data, **so that** I can drive
CloudFormation deployments from a single parameterized file without duplication.

**Acceptance Criteria:**

- A document with both `$defs` and `$imports` at the root mapping level is
  valid input.
- `$defs` and `$imports` keys do not appear in the preprocessed output.
- Variables defined in `$defs` are available to the body and to subsequent
  `$defs` entries and `$imports` location strings.
- Import locations support Handlebars interpolation: `./config-{{ env }}.yaml`
  is expanded using the current environment before the file is loaded.
- The preprocessing result carries both the resolved value and an import
  manifest recording what was imported.

**Import manifest record structure:**

```pseudocode
type ImportRecord =
  { key        :: Maybe Text    -- import key name (Nothing for root document)
  , from       :: Text          -- importing document location
  , imported   :: Text          -- resolved import location
  , sha256Digest :: Text        -- SHA256 hex digest of raw imported content
  }
```

**Logic Flow:**

1. Parse root mapping; locate `$defs` and `$imports` sub-mappings.
2. Fold over `$defs` pairs in order, resolving each value against the
   accumulated environment.
3. For each `$imports` entry: interpolate the location string, load the import,
   add result to environment. If the imported document contains `$params`,
   register it as a custom resource template.
4. Build the variable scope from the final environment; resolve the full
   document AST (filtering out `$defs`/`$imports` special keys from output).
5. Apply YAML 1.1 compat post-pass if requested.

**Edge Cases:**

- A document with no `$defs` or `$imports` is valid; Phase 1 is a no-op.
- If `$defs` is present but empty, environment is unchanged.
- If `$imports` is present but empty, no imports are loaded.
- A `$defs` value that itself uses `!$` can only reference variables defined
  earlier in the same `$defs` block, not later ones (let* semantics, not
  parallel/letrec).
- Import location strings are Handlebars-interpolated but not otherwise
  preprocessed as YAML at the location-string stage.

**Error Scenarios:**

- ERR_3001: Import file path does not exist.
- ERR_3004: Circular import detected (cycle in import graph).
- ERR_6001: Handlebars syntax error in an import location string.
- ERR_2001: Variable referenced in an import location string is not defined.

**Complexity Notes:**

`$defs` processing folds sequentially over the pairs list with an accumulating
environment. Import processing is sequential to preserve deterministic ordering
and to allow each import to be available to subsequent import location strings.

---

### US-02-002: Use variable lookup tags (!$) with dot, bracket, and query notation

**As a** Developer, **I want to** look up variables from the environment using
`!$` with dot notation, bracket notation, and query selectors, **so that** I
can access deeply nested data without manual extraction.

**Accepted tag forms:** `!$` and `!$include` (alias -- identical behavior, the
parser treats `!$include` as a synonym for `!$`).

**Acceptance Criteria:**

- `!$ varname` resolves the variable `varname` from the current scope.
- `!$ a.b.c` traverses nested objects: looks up `a`, then `.b`, then `.c`.
- `!$ arr.0` retrieves index 0 from a sequence.
- `!$ config[environment]` resolves `environment` to a string, then looks up
  that string as a key in `config`.
- `!$ config.database?host,port` returns a new mapping containing only the
  listed keys from `config.database`.
- Object form with `path` + `query` is equivalent to the `?` inline syntax.
- Object form with `path` + `jmespath` applies a JMESPath expression to the
  resolved base value.
- `query` and `jmespath` fields are mutually exclusive.

**Tag argument types:**

```pseudocode
type VarLookupTag =
  { path     :: Text          -- dot/bracket path (required)
  , query    :: Maybe Text    -- comma-separated key selection
  , jmesPath :: Maybe Text    -- JMESPath expression
  }
-- Constructed from:
--   Scalar string: "path?query" parsed into path + query
--   Mapping: { path: "...", query: "...", jmespath: "..." }
-- Returns: OValue (the resolved value)
```

**Logic Flow:**

1. Parse the `!$` value. Scalar string: treat as path (optionally with `?query`
   suffix). Mapping: extract `path`, `query`, and `jmespath` fields.
2. Expand bracket notation: replace `[varname]` segments by resolving `varname`
   in the current context and substituting its string representation.
3. Split path on `.` and traverse the environment.
4. If a query is present, apply comma-separated key selection: produce a
   filtered mapping; all keys must exist.
5. If a JMESPath expression is present, apply the JMESPath evaluator to the
   resolved value.

**Edge Cases:**

- `!$ this` is not a special keyword in `!$` context (unlike Handlebars). It
  looks up the variable literally named "this".
- Bracket expansion is recursive: `a[b][c]` expands both brackets in sequence.
- A numeric string segment in a dot path accesses a sequence by index:
  `!$ list.0` returns the first element.
- A query applied to a non-mapping value produces null, not an error, for
  single-key traversal forms. Comma-separated key selection against a
  non-mapping value returns null.
- An empty query string after `?` is treated as a no-op.

**Error Scenarios:**

- ERR_2001: Variable root name not found in current scope. Error message lists
  available variable names.
- ERR_2006: Comma-separated query key not found in the target mapping. Error
  message lists available keys.
- ERR_2006: JMESPath expression syntactically invalid or evaluation fails.
- ERR_4003: Both `query` and `jmespath` specified in object form.

**Complexity Notes:**

Bracket expansion is performed recursively, processing the path until no more
brackets are found. The JMESPath evaluator must be implemented as a custom
component covering the full spec (projections, filters, multi-select hash/list,
functions), as no standard library provides the required subset.

---

### US-02-003: Use conditional logic (!$if, !$eq, !$not)

**As a** Developer, **I want to** express conditional values that vary by
environment or configuration, **so that** a single template can cover multiple
deployment targets without duplication.

**Acceptance Criteria:**

- `!$if` requires a `test` field and a `then` field. The `else` field is
  optional; if omitted and the test is falsy, the result is null.
- `!$if` evaluates `test`, resolves `then` if truthy, `else` if falsy.
- `!$eq` takes a two-element sequence and returns true if both resolved values
  are structurally equal, false otherwise.
- `!$not` takes a one-element sequence and returns the logical negation of the
  resolved value's truthiness.
- Truthiness uses **preprocessing truthiness** rules (see Technical Context):
  null, boolean false, empty string `""`, empty array `[]`, empty object `{}`,
  and **zero** are all **falsy**. All other values are truthy (non-empty
  strings, non-zero numbers, non-empty arrays, non-empty objects, boolean true).
- `!$if` can be nested arbitrarily inside `then` and `else` branches.
- There are no `!$and` or `!$or` tags. Compound conditions use nested `!$if`.

**Tag argument types and return types:**

```pseudocode
-- !$if
type IfTag = { test :: YamlAst, then :: YamlAst, else :: Maybe YamlAst }
resolve_if(ctx, tag) -> OValue:
  testVal = resolve(ctx, tag.test)
  if oIsTruthy(testVal): return resolve(ctx, tag.then)
  else: return resolve(ctx, tag.else) or ONull

-- !$eq
type EqTag = { left :: YamlAst, right :: YamlAst }
resolve_eq(ctx, tag) -> OBool:
  return OBool(resolve(ctx, tag.left) == resolve(ctx, tag.right))

-- !$not
type NotTag = { expression :: YamlAst }
resolve_not(ctx, tag) -> OBool:
  return OBool(not(oIsTruthy(resolve(ctx, tag.expression))))
```

**Logic Flow:**

1. `!$if`: resolve the `test` expression; if truthy, resolve and return `then`;
   else resolve and return `else` (or null if absent).
2. `!$eq`: resolve both arms; compare with structural deep equality.
3. `!$not`: resolve the single child; return the logical negation of its
   truthiness.

**Edge Cases:**

- `!$if` with `else: null` explicitly and `!$if` with no `else` key both yield
  null on a falsy test.
- `!$eq` on values of different types is always `False` (e.g. string `"1"` vs
  number `1`).
- `!$not` on a non-boolean value negates the truthiness coercion, not a type
  error.
- An empty string is falsy; a string containing `"false"` is truthy (it is a
  non-empty string).
- The number `0` is falsy (unlike Handlebars `{{#if}}` where all numbers are
  truthy).

**Error Scenarios:**

- ERR_4002: `test` or `then` field missing from `!$if` mapping.
- ERR_4003: `!$if` value is not a mapping (e.g. written as a scalar).
- ERR_4002: `!$eq` not given exactly two elements.
- ERR_4002: `!$not` not given exactly one element.

**Complexity Notes:**

Resolution is fully lazy across branches: the non-taken branch of `!$if` is
never resolved. This means errors in the non-taken branch do not surface, which
is intentional and matches Rust behavior.

---

### US-02-004: Transform collections (!$map, !$merge, !$concat, and variants)

**As a** Developer, **I want to** apply collection-transforming tags to lists
and mappings, **so that** I can generate repetitive CloudFormation resources,
merge environment overrides, and restructure data without manual copy-paste.

**Acceptance Criteria:**

**!$map:** Applies a `template` expression to each element of an `items`
sequence. The loop variable (default `item`, configurable via `var`) and its
zero-based index (`itemIdx` or `varIdx`) are bound in each iteration. An
optional `filter` expression, evaluated per item, excludes items for which it
is falsy. Returns a sequence.

```pseudocode
type MapTag = { items :: YamlAst, template :: YamlAst, var :: Maybe Text, filter :: Maybe YamlAst }
resolve_map(ctx, tag) -> OArray:
  items = resolve(ctx, tag.items)       -- must be OArray
  varName = tag.var or "item"
  results = []
  for i, item in enumerate(items):
    innerCtx = withVariable(varName, item, withVariable(varName + "Idx", i, ctx))
    if tag.filter:
      filterVal = resolve(innerCtx, tag.filter)
      if not oIsTruthy(filterVal): continue
    results.append(resolve(innerCtx, tag.template))
  return OArray(results)
```

**!$concatMap:** Like `!$map` but each `template` must produce a sequence; all
results are concatenated into one flat list. Non-sequence template results are
wrapped as single-element lists.

```pseudocode
type ConcatMapTag = { items :: YamlAst, template :: YamlAst, var :: Maybe Text, filter :: Maybe YamlAst }
resolve_concatMap(ctx, tag) -> OArray:
  mapped = resolve_map(ctx, tag)   -- reuses !$map logic
  return OArray(concatMap(flatten, mapped))
  where flatten(OArray inner) = inner
        flatten(other)        = [other]
```

**!$concat:** Takes a sequence of sequences and concatenates them into one flat
list. Non-sequence items are flattened to single-element contribution.

```pseudocode
type ConcatTag = { sources :: [YamlAst] }
resolve_concat(ctx, tag) -> OArray:
  vals = [resolve(ctx, src) | src <- tag.sources]
  return OArray(concatMap(flatten, vals))
  where flatten(OArray inner) = inner
        flatten(other)        = [other]
```

**!$merge:** Takes a sequence of mappings and deep-merges them left to right.

```pseudocode
resolve_merge(ctx, sources) -> OObject:
  result = OObject([])
  for source in sources:
    val = resolve(ctx, source)   -- must be OObject
    result = mergeOObjects(result, val)
  return result

mergeOObjects(base, overlay) -> OObject:
  -- Keys from base appear first in insertion order
  -- If a key exists in both: value from overlay replaces base value
  -- New keys from overlay are appended after base keys
  result = [(k, overlay[k] if k in overlay else v) for (k, v) in base]
  result += [(k, v) for (k, v) in overlay if k not in base]
  return OObject(result)
```

**!$mergeMap:** Like `!$map` (supports `items`, `template`, `var`) but each
`template` must produce a mapping; all results are merged left to right.

```pseudocode
type MergeMapTag = { items :: YamlAst, template :: YamlAst, var :: Maybe Text }
resolve_mergeMap(ctx, tag) -> OObject:
  mapped = resolve_map(ctx, tag)   -- reuses !$map logic (no filter support)
  result = OObject([])
  for val in mapped:
    assert val is OObject   -- type error otherwise
    result = mergeOObjects(result, val)
  return result
```

**!$mapListToHash:** Like `!$map` (supports `items`, `template`, `var`,
`filter`) but each `template` must produce either a two-element sequence
`[key, value]`, a single-key mapping `{key: value}`, or a mapping with `key`
and `value` fields. All results are merged into one mapping.

```pseudocode
type MapListToHashTag = { items :: YamlAst, template :: YamlAst, var :: Maybe Text, filter :: Maybe YamlAst }
resolve_mapListToHash(ctx, tag) -> OObject:
  mapped = resolve_map(ctx, tag)   -- reuses !$map logic
  pairs = []
  for val in mapped:
    case val of
      OArray [k, v]                                     -> pairs.append((toText(k), v))
      OObject [(k, v)]                                  -> pairs.append((k, v))
      OObject kvs | has("key",kvs) && has("value",kvs)  -> pairs.append((toText(kvs["key"]), kvs["value"]))
      _                                                 -> error(TypeMismatch)
  return OObject(pairs)
```

**!$fromPairs:** Takes a pre-built sequence of two-element sequences `[key,
value]` and converts it directly to a mapping. Does not iterate -- expects the
sequence already built.

```pseudocode
type FromPairsTag = { source :: YamlAst }
resolve_fromPairs(ctx, tag) -> OObject:
  sourceVal = resolve(ctx, tag.source)   -- must be OArray
  pairs = []
  for val in sourceVal:
    assert val is OArray of length 2
    pairs.append((toText(val[0]), val[1]))
  return OObject(pairs)
```

**!$mapValues:** Takes a mapping as `items`; applies `template` to each value.
The loop variable (default `item`) is bound to a mapping `{key: K, value: V}`
for each entry. Returns a mapping with the same keys and transformed values.

```pseudocode
type MapValuesTag = { items :: YamlAst, template :: YamlAst, var :: Maybe Text }
resolve_mapValues(ctx, tag) -> OObject:
  obj = resolve(ctx, tag.items)   -- must be OObject
  varName = tag.var or "item"
  results = []
  for (key, value) in obj:
    binding = OObject([("key", OString(key)), ("value", value)])
    innerCtx = withVariable(varName, binding, ctx)
    results.append((key, resolve(innerCtx, tag.template)))
  return OObject(results)
```

**!$groupBy:** Takes a sequence as `items`; evaluates a `key` expression per
item (with the loop variable in scope) and groups items into a mapping of
`key -> [item, ...]`. Group insertion order within the result mapping is
non-deterministic (HashMap internally).

```pseudocode
type GroupByTag = { items :: YamlAst, key :: YamlAst, var :: Maybe Text, template :: Maybe YamlAst }

resolve_groupBy(ctx, tag):
  itemsVal = resolve(ctx, tag.items)
  assert itemsVal is OArray, else typeMismatchError("sequence", itemsVal)
  groups = []  -- association list preserving insertion order
  for item in itemsVal:
    itemCtx = withVariable(tag.var ?? "item", item, ctx)
    keyVal = resolve(itemCtx, tag.key)
    k = oValueToText(keyVal)
    existing = lookupO(k, groups) ?? OArray([])
    groups = insertO(k, OArray(existing ++ [item]), groups)
  return OObject(groups)
```

**Logic Flow (shared for iteration tags):**

1. Resolve `items` expression.
2. Assert items is the required type (sequence for map/concatMap/concat/
   concatMap/mapListToHash/groupBy; mapping for mapValues).
3. For each item (or pair): extend context with loop variable and index bindings;
   resolve `template` (and `filter` if present); collect results.
4. Post-process results into the target shape (list, flat list, merged mapping).

**Edge Cases:**

- Empty `items` sequence: all iteration tags return an empty result without
  error.
- `!$map` with `filter` that excludes all items returns an empty sequence.
- `!$concatMap` template returning a non-sequence is treated as a single-element
  list (not an error).
- `!$merge` with a non-mapping source is a type error.
- `!$mergeMap` with a template producing a non-mapping is a type error.
- `!$mapListToHash` template producing a sequence with more or fewer than 2
  elements is a type error.
- `!$groupBy` result key ordering is not guaranteed.
- `!$concat` with non-sequence items: each non-sequence element is treated as a
  single-element contribution to the concatenated result.

**Error Scenarios:**

- ERR_4002: `items` or `template` field missing.
- ERR_5001: `items` value is not the required type (sequence or mapping).
- ERR_5001: `!$merge` source is not a mapping.
- ERR_5001: `!$mergeMap` template produced a non-mapping.
- ERR_5001: `!$mapListToHash` template item is not a 2-element sequence or
  supported mapping form.

**Complexity Notes:**

`!$mergeMap` merges preserving key order: keys from the base that are also in
the overlay retain their position but take the overlay value; new overlay keys
are appended. This makes merge order significant and predictable.

---

### US-02-005: Use string and serialization tags (!$join, !$split, !$toJsonString, etc.)

**As a** Developer, **I want to** join, split, serialize, and parse string and
structured data within my template, **so that** I can construct strings from
parts, pass JSON blobs as CloudFormation parameter values, and round-trip
structured data through string representations.

**Tag argument types and return types:**

```pseudocode
-- !$join [delimiter, list] -> OString
type JoinTag = { delimiter :: YamlAst, array :: YamlAst }
-- List items must be string-convertible scalars (strings, numbers, booleans, nulls)

-- !$split [delimiter, string] -> OArray of OString
type SplitTag = { delimiter :: YamlAst, string :: YamlAst }

-- !$toYamlString content -> OString        (alias: !$string)
type ToYamlStringTag = { data :: YamlAst }

-- !$parseYaml content -> OValue
type ParseYamlTag = { string :: YamlAst }

-- !$toJsonString content -> OString
type ToJsonStringTag = { data :: YamlAst }

-- !$parseJson content -> OValue
type ParseJsonTag = { string :: YamlAst }
```

**Acceptance Criteria:**

**!$join:** Takes a two-element sequence `[delimiter, list]`. Resolves both
elements. Joins the list items with the delimiter. All list items must be
string-convertible scalars (strings, numbers, booleans, nulls). Objects and
sequences are type errors.

**!$split:** Takes a two-element sequence `[delimiter, string]`. Splits the
string on the delimiter. Returns a sequence of strings. Splitting on an empty
string produces single-character elements.

**!$toYamlString:** Resolves its content value and serializes it to a YAML
string (preserving key order). The deprecated alias `!$string` is accepted.

**!$parseYaml:** Resolves its content to a string and parses it as YAML.
Returns the parsed structure. Uses the same YAML parser as the main pipeline.

**!$toJsonString:** Resolves its content value and serializes it to a compact
JSON string (no whitespace).

**!$parseJson:** Resolves its content to a string and parses it as JSON.
Returns the parsed structure.

**Logic Flow:**

```pseudocode
resolve_toYamlString(ctx, tag):    -- also handles !$string alias
  val = resolve(ctx, tag.data)
  return OString(emitYaml(val))

resolve_toJsonString(ctx, tag):
  val = resolve(ctx, tag.data)
  return OString(encodeJson(val))

resolve_parseYaml(ctx, tag):
  str = resolve(ctx, tag.string)
  assert str is OString, else typeMismatchError("string", str)
  return parseYaml(str)

resolve_parseJson(ctx, tag):
  str = resolve(ctx, tag.string)
  assert str is OString, else typeMismatchError("string", str)
  return parseJson(str)
```

- All six tags resolve their input first, then perform their string/parse
  operation.
- `!$join` validates each item type before joining.
- `!$parseYaml` and `!$parseJson` parse the string and return the structured
  value.

**Edge Cases:**

- `!$join` with an empty list produces an empty string.
- `!$split` with a delimiter that does not appear in the string returns a
  single-element list containing the entire string.
- `!$split ["", "abc"]` splits into `["a", "b", "c"]`.
- `!$toYamlString` on a scalar string produces a YAML scalar (possibly quoted).
- `!$parseYaml` on a string containing multiple YAML documents parses only the
  first.
- `!$toJsonString` on a mapping serializes via the JSON encoder; key order in
  the JSON output may not match the original insertion order.

**Error Scenarios:**

- ERR_5001: `!$join` list contains an object or sequence.
- ERR_5001: `!$join` delimiter is not a string.
- ERR_5001: `!$join` list argument is not a sequence.
- ERR_5001: `!$split` delimiter or string is not a string.
- ERR_1001: `!$parseYaml` input is not valid YAML.
- ERR_1001: `!$parseJson` input is not valid JSON.
- ERR_5001: `!$parseYaml` or `!$parseJson` applied to a non-string value.

**Complexity Notes:**

`!$toYamlString` uses the same YAML emitter as the final output pipeline,
guaranteeing consistent formatting and key-order preservation. `!$parseYaml`
parses the string without tag resolution, so preprocessing tags inside the
string are treated as literal data rather than being expanded.

---

### US-02-006: Use local bindings (!$let), preprocessing escape (!$escape), and template expansion (!$expand)

**As a** Developer, **I want to** introduce scoped local variables within an
expression, selectively suppress preprocessing on parts of the output, and
explicitly expand registered custom resource templates, **so that** I can
compute intermediate values without polluting the global `$defs` scope, emit
literal data structures that should not be transformed, and reuse template
definitions outside of the automatic `Resources` expansion.

**Tag argument types and return types:**

```pseudocode
-- !$let
type LetTag = { bindings :: [(Text, YamlAst)], expression :: YamlAst }
resolve_let(ctx, tag) -> OValue:
  innerCtx = ctx
  for (name, valueAst) in tag.bindings:    -- let* semantics
    resolved = resolve(innerCtx, valueAst)
    innerCtx = withVariable(name, resolved, innerCtx)
  return resolve(innerCtx, tag.expression)

-- !$escape
type EscapeTag = { content :: YamlAst }
resolve_escape(tag) -> OValue:
  return astToValueRaw(tag.content)   -- no tag resolution, no Handlebars interpolation

-- !$expand
type ExpandTag = { templateRef :: YamlAst, params :: YamlAst }
resolve_expand(ctx, tag) -> OValue:
  templateName = toText(resolve(ctx, tag.templateRef))
  if templateName in ctx.activeExpansions: error(CircularExpansion)
  tmplInfo = lookupTemplate(templateName, ctx.customTemplateDefs)
  if tmplInfo is Nothing: error(ExpandNotFound, templateName)
  provided = resolve(ctx, tag.params)   -- must be OObject
  merged = mergeWithDefaults(tmplInfo.params, provided)
  templateAst = parseYaml(tmplInfo.rawBody, tmplInfo.location)
  subCtx = ctx { variables = merged `union` ctx.variables,
                 inputUri = tmplInfo.location,
                 activeExpansions = insert(templateName, ctx.activeExpansions) }
  return resolveAst(subCtx, templateAst)
```

**Acceptance Criteria:**

**!$let:**

- The `!$let` tag value must be a mapping.
- Every key except `in` is a binding. Keys are resolved in order (let*
  semantics, same as `$defs`): each binding may reference earlier bindings
  defined in the same `!$let`.
- The `in` key holds the expression to evaluate with all bindings in scope.
- `in` is required; its absence is a parse error.
- `!$let` bindings shadow outer variables for the duration of the `in`
  expression.
- `!$let` does not affect the outer scope; bindings are purely local.

**!$escape:**

- The `!$escape` tag wraps a YAML value. Its content is converted to a plain
  value by skipping all tag resolution.
- Tags inside `!$escape` are represented as literal strings (`"!$escaped"` for
  preprocessing tags; as single-key objects for CloudFormation tags).
- Handlebars expressions inside strings within `!$escape` are NOT interpolated.
- The result is a plain data structure that passes through to output unchanged.

**Logic Flow for !$let:**

1. Parse the tag value as a mapping; locate the `in` key.
2. Collect all other keys as bindings.
3. Fold over bindings in order: for each, resolve the value against the current
   accumulated context; add to context.
4. Resolve the `in` expression against the final accumulated context.

**Logic Flow for !$escape:**

1. Convert the inner AST to a plain value without invoking tag resolution.
2. Return the resulting value directly.

**Edge Cases:**

- A `!$let` with no bindings (only an `in` key) is valid; it evaluates `in` in
  the current scope unchanged.
- A `!$let` binding that shadows an outer variable: the outer value is
  inaccessible within the `in` expression for the shadowed name.
- `!$escape` on a plain scalar: returns the scalar unchanged.
- `!$escape` on a mapping containing `!$map`: the `!$map` tag becomes the
  string `"!$escaped"` in the output.
- `!$escape` on a mapping containing a CloudFormation tag (e.g. `!Ref`):
  produces `{"!Ref": "LogicalId"}` as an object, not a YAML tag.

**!$expand:**

- The `!$expand` tag explicitly invokes a registered custom resource template.
- The first child (scalar or mapping key `template`) identifies the template
  name, which must match a key from `$imports` that had a `$params` section.
- The second child (or `params` mapping key) provides parameter values.
- Parameters are merged with the template's `$params` defaults: provided values
  override defaults; missing parameters without defaults are omitted.
- Circular expansion is detected via `activeExpansions` and produces an error.
- See `04-custom-resources.md` for the full custom resource expansion pipeline
  including automatic expansion in `Resources` sections.

**Error Scenarios:**

- ERR_4002: `!$let` value is not a mapping.
- ERR_4002: `in` key missing from `!$let` mapping.
- ERR_2001: Variable referenced in a `!$let` binding references a name not yet
  defined in that `!$let` block and not in the outer scope.
- ERR_4002: `!$expand` template name not found in registered custom templates.
- ERR_9001: Circular `!$expand` detected (template expanding itself).

**Complexity Notes:**

`!$let` bindings use the same sequential folding pattern as `$defs` processing:
the context is threaded through each step, giving let* semantics without any
special logic. `!$escape` is intentionally simple: it performs a structural
conversion with no I/O and no error path.

---

### US-02-007: Use Handlebars interpolation with helpers

**As a** Developer, **I want to** embed `{{ }}` expressions in string values
to interpolate variables and call helper functions for string formatting,
encoding, and serialization, **so that** I can construct dynamic strings without
using `!$join` for every concatenation.

**Template syntax:**

- Any string value containing `{{` is processed as a Handlebars template.
- `{{ varname }}` outputs the string representation of the variable.
- `{{ a.b.c }}` accesses nested properties via dot path.
- `{{ helperName arg1 arg2 }}` calls a helper with positional arguments.
- `{{ (eq a b) }}` is a sub-expression calling helper `eq` inline.
- `{{#if expr}}...{{/if}}` and `{{#unless expr}}...{{/unless}}` are block
  conditionals.
- `{{#each list}}...{{/each}}` iterates; `{{this}}`, `{{@index}}`,
  `{{@first}}`, `{{@last}}` are available inside.
- `{{#each obj}}...{{/each}}` iterates object entries; `{{this}}` is the value,
  `{{@key}}` is the key.
- `{{#with expr}}...{{/with}}` changes the context to the resolved value.
- `{{! comment text }}` is a comment; produces no output.
- Unknown helpers produce ERR_6002.
- Unclosed `{{` or block tags produce ERR_6001.

**All 25 helpers:**

String case (8):

| Helper         | Signature                      | Return type | Behavior                                                          |
|----------------|--------------------------------|-------------|-------------------------------------------------------------------|
| `toLowerCase`  | `toLowerCase str`              | String      | All characters to lower case                                      |
| `toUpperCase`  | `toUpperCase str`              | String      | All characters to upper case                                      |
| `capitalize`   | `capitalize str`               | String      | First character to upper case; rest unchanged                     |
| `titleize`     | `titleize str`                 | String      | First character of each whitespace-separated word to upper case   |
| `camelCase`    | `camelCase str`                | String      | Split on separators (-, _, space, .) then lowerFirst + TitleCase  |
| `pascalCase`   | `pascalCase str`               | String      | Split on separators then TitleCase each word                      |
| `snakeCase`    | `snakeCase str`                | String      | Split on separators then join with `_` in lower case              |
| `kebabCase`    | `kebabCase str`                | String      | Split on separators then join with `-` in lower case              |

String manipulation (6):

| Helper      | Signature                                   | Return type | Behavior                                     |
|-------------|---------------------------------------------|-------------|----------------------------------------------|
| `trim`      | `trim str`                                  | String      | Strip leading/trailing whitespace             |
| `replace`   | `replace str search replacement`            | String      | Replace all occurrences (not regex)           |
| `substring` | `substring str start length`                | String      | Extract substring by char offset and length   |
| `length`    | `length str\|array\|object`                 | String      | Character count, element count, or key count  |
| `pad`       | `pad str targetLength [padChar]`            | String      | Right-pad to target length; default `" "`     |
| `concat`    | `concat str1 str2 ...`                      | String      | Concatenate all arguments as strings          |

Encoding (3):

| Helper           | Signature                | Return type | Behavior                                            |
|------------------|--------------------------|-------------|-----------------------------------------------------|
| `base64`         | `base64 str`             | String      | Base64-encode UTF-8 bytes of input string           |
| `urlEncode`      | `urlEncode str`          | String      | Percent-encode non-unreserved characters (RFC 3986) |
| `sha256`         | `sha256 str`             | String      | SHA-256 of UTF-8 bytes; output as lowercase hex     |

Serialization (6, including deprecated aliases):

| Helper         | Signature              | Return type | Behavior                                     |
|----------------|------------------------|-------------|----------------------------------------------|
| `toJson`       | `toJson value`         | String      | Compact JSON string (no whitespace)           |
| `tojson`       | `tojson value`         | String      | Deprecated alias for `toJson`                 |
| `toJsonPretty` | `toJsonPretty value`   | String      | Pretty-printed JSON string                    |
| `tojsonPretty` | `tojsonPretty value`   | String      | Deprecated alias for `toJsonPretty`           |
| `toYaml`       | `toYaml value`         | String      | YAML string using the custom emitter + `\n`   |
| `toyaml`       | `toyaml value`         | String      | Deprecated alias for `toYaml`                 |

Object access (1):

| Helper   | Signature             | Return type | Behavior                                                             |
|----------|-----------------------|-------------|----------------------------------------------------------------------|
| `lookup` | `lookup obj key`      | Value       | Get property from object or element from array by index; empty string if not found |

Equality (1):

| Helper | Signature   | Return type | Behavior                                        |
|--------|-------------|-------------|-------------------------------------------------|
| `eq`   | `eq a b`    | Bool        | Returns boolean; primarily for `{{#if (eq a b)}}` |

**Logic Flow:**

```pseudocode
interpolate(helpers, context, template):
  if "{{" not in template: return template    -- fast path
  parts = parseTemplate(template)             -- recursive-descent parser
  return renderParts(helpers, context, parts)

renderPart(helpers, ctx, part):
  case part of
    Literal text  -> text
    Comment       -> ""
    Output expr   -> valueToString(evalExpr(helpers, ctx, expr))
    Block "if" condExpr body elseBody ->
      if handlebars_isTruthy(evalExpr(helpers, ctx, condExpr)):
        renderParts(helpers, ctx, body)
      else: renderParts(helpers, ctx, elseBody) or ""
    Block "each" expr body elseBody ->
      case evalExpr(helpers, ctx, expr) of
        Array arr  -> concat [renderParts(helpers, mergeCtx(ctx, {this: item, @index: i, @first: i==0, @last: i==len-1}), body) | (i, item) <- enumerate(arr)]
        Object obj -> concat [renderParts(helpers, mergeCtx(ctx, {this: v, @key: k}), body) | (k, v) <- entries(obj)]
        _          -> renderParts(helpers, ctx, elseBody) or ""
    Block "with" expr body elseBody ->
      val = evalExpr(helpers, ctx, expr)
      if handlebars_isTruthy(val): renderParts(helpers, mergeCtx(ctx, val), body)
      else: renderParts(helpers, ctx, elseBody) or ""
```

**Edge Cases:**

- A Handlebars template that produces a non-string value (e.g. a number or
  boolean) is coerced: numbers render as their decimal representation; booleans
  as `"true"` / `"false"`; null as `""`.
- `{{#each}}` on a non-array, non-object falls through to the else branch (if
  present) or produces empty string.
- `{{#with}}` on a falsy value uses the else branch.
- `length` on a string returns character count as a string; on an array returns
  element count as a string; on an object returns key count as a string.
- `lookup` on an array with a non-integer string key returns empty string.
- camelCase word splitter recognizes runs of uppercase letters as an acronym
  boundary: `"XMLParser"` splits to `["XML", "Parser"]`.
- Handlebars `{{#if}}` uses Handlebars truthiness (all numbers including zero
  are truthy), NOT preprocessing truthiness. This differs from `!$if`.

**Error Scenarios:**

- ERR_2001: A `{{varname}}` reference where `varname` is not in the current
  scope. The pre-check fires before rendering begins and lists available
  variables.
- ERR_6001: Unclosed `{{`, unclosed block (`{{#if}}` with no `{{/if}}`),
  unexpected `{{/name}}` without a matching open.
- ERR_6002: `{{ unknownHelper arg }}` where `unknownHelper` is not in the
  helper registry.
- ERR_6003: A helper called with the wrong number or wrong type of arguments
  (e.g. `replace` called with fewer than 3 arguments).

**Complexity Notes:**

The Handlebars engine must be implemented as a custom recursive-descent parser;
no external Handlebars library is used. Sub-expressions `(helperName args)` allow
helpers to be nested as arguments to other helpers or block conditions. The `each`
block exposes `@index`, `@first`, `@last` for arrays and `@key` for objects.

---

### US-02-008: Handle YAML 1.1 vs 1.2 compatibility

**As a** Platform Engineer or CI Pipeline, **I want to** control whether
boolean-like string values are converted to actual booleans, **so that**
existing CloudFormation templates that use `yes`/`no`/`on`/`off` continue to
work correctly, while new documents use strict YAML 1.2 semantics.

**Acceptance Criteria:**

- Default mode is YAML 1.2: boolean-like strings remain as strings.
- YAML 1.1 compat mode converts the 18 boolean-like strings to actual booleans:
  `true`, `false`, `yes`, `no`, `on`, `off` and their `Title` and `UPPER` case
  variants.
- `isTrueIsh` considers `true`, `yes`, `on` (case-insensitive) as `True`; all
  others (`false`, `no`, `off`) as `False`.
- The `--yaml-spec` CLI flag accepts `auto`, `1.1`, or `1.2`.
  - `auto`: auto-detect by document content.
  - `1.1`: force YAML 1.1 compat.
  - `1.2`: force strict YAML 1.2.
- Auto-detection logic:
  - A `%YAML 1.1` directive in the first 5 lines: compat on.
  - A `%YAML 1.2` directive in the first 5 lines: compat off.
  - Document contains 2+ CloudFormation keys in first 50 lines
    (`AWSTemplateFormatVersion`, `Resources:`, `Parameters:`, `Outputs:`,
    `Conditions:`, `Mappings:`, `Metadata:`, `Transform:`): compat on.
  - Document contains both `apiVersion:` and `kind:` plus a recognized Kubernetes
    API version string in first 20 lines: compat off.
  - Otherwise: compat off.

**Conversion logic:**

```pseudocode
convertYaml11Compat(value):
  case value of
    OObject kvs -> OObject [(k, convertYaml11Compat(v)) | (k, v) <- kvs]
    OArray items -> OArray [convertYaml11Compat(v) | v <- items]
    OString s | isBooleanLike(s) -> OBool(isTrueIsh(s))
    other -> other

isBooleanLike(s):
  s in {"true","false","yes","no","on","off",
        "True","False","Yes","No","On","Off",
        "TRUE","FALSE","YES","NO","ON","OFF"}

isTrueIsh(s):
  toLower(s) in {"true","yes","on"}
```

**Logic Flow:**

1. Detect YAML spec from raw input text before parsing when `--yaml-spec auto`
   or the default is active.
2. Determine whether YAML 1.1 compatibility mode should be enabled.
3. Run the appropriate preprocessing pipeline variant accordingly.
4. After Phase 2, if YAML 1.1 compat: walk the resolved value recursively;
   for every string that matches a boolean-like pattern, replace it with an
   actual boolean.

**Edge Cases:**

- YAML 1.1 conversion is a post-pass over the fully resolved value, not applied
  during parsing. This means a string produced by `!$join` that happens to spell
  `"yes"` is also converted.
- The 18 recognized strings are case-sensitive membership: `True` converts but
  `tRue` does not.
- YAML 1.1 conversion does not affect numbers or existing booleans.
- CloudFormation auto-detection requires at least 2 matching keys (not just 1)
  to avoid false positives.

**Error Scenarios:**

- ERR_8001: Invalid `--yaml-spec` value (not `auto`, `1.1`, or `1.2`).

**Complexity Notes:**

YAML 1.1 boolean conversion is a recursive structural fold over the output
value. The conversion happens after full resolution, so it interacts with all
other features uniformly -- including strings produced by `!$join` or Handlebars
interpolation.

---

### US-02-009: Handle preprocessing errors with position tracking

**As a** Developer or CI Pipeline, **I want to** receive errors that include
the exact file, line, and column of the problem, along with the surrounding
YAML context and a corrective example, **so that** I can immediately locate and
fix the issue without guessing.

**Error type hierarchy:**

```pseudocode
type PreprocessError =
  | PeResolveError   ResolveError
  | PeImportError    ImportError
  | PeHandlebarsError InterpolateError
  | PeCycleError     Text

type ResolveError = { position :: Position, kind :: ResolveErrorKind, message :: Text }

type ResolveErrorKind =
  | REVariableNotFound   { path :: Text, availableVars :: [Text] }
  | REJmesPath           { expr :: Text, detail :: Text, varPath :: Text }
  | REPropertyNotFound   { missingKey :: Text, varPath :: Text, availableKeys :: [Text] }
  | RETypeMismatch       { expected :: Text, found :: Text, contextTag :: Maybe Text }
  | RECfnValidation      { cfnTagName :: Text }
  | REHandlebars
  | RETagSyntax          { tagName :: Maybe Text }
  | REExpandNotFound     { templateName :: Text }
  | RECircularExpansion  { templateName :: Text }
  | REParseSyntax
  | REGeneric
```

**Acceptance Criteria:**

- Every preprocessing error carries a position (line, column) from the AST
  node where the error occurred.
- Position is reported in 1-based line and column numbers.
- The error display renders a 3-line context window around the error position,
  with a caret (`^^^`) under the relevant span.
- Every error includes an `errno` in the format `ERR_NNNN` referencing the
  error code catalogue.
- The `iidy explain ERR_NNNN` command explains the error code in detail with
  examples.
- All error categories carry their numeric code:

| Range     | Category                         |
|-----------|----------------------------------|
| 1001-1005 | YAML syntax and parsing          |
| 2001-2006 | Variable and scope errors        |
| 3001-3010 | Import and loading errors        |
| 4001-4005 | Tag syntax and structure errors  |
| 5001-5006 | Type and validation errors       |
| 6001-6005 | Handlebars template errors       |
| 7001-7004 | CloudFormation intrinsic errors  |
| 8001-8005 | Configuration and CLI errors     |
| 9001-9005 | Internal and system errors       |

**Key error codes for preprocessing:**

| Code     | Name                           | Triggered by                                                    |
|----------|--------------------------------|-----------------------------------------------------------------|
| ERR_1001 | InvalidYamlSyntax              | Malformed YAML input                                            |
| ERR_2001 | VariableNotFound               | `!$` path root not in scope; `{{var}}` root not in scope       |
| ERR_2006 | LookupQueryFailed              | Comma-separated key missing from mapping; JMESPath failure      |
| ERR_4001 | UnknownPreprocessingTag        | Tag spelled incorrectly (e.g. `!$mapp`)                        |
| ERR_4002 | MissingRequiredTagField        | Required tag field absent (e.g. `template` missing from `!$map`) |
| ERR_4003 | InvalidTagFieldValue           | Field value is the wrong type or an illegal combination         |
| ERR_5001 | TypeMismatchInOperation        | Tag received wrong value type (e.g. sequence where mapping expected) |
| ERR_6001 | HandlebarsSyntaxError          | Unclosed `{{`, unclosed block tag, unexpected close tag         |
| ERR_6002 | UnknownHandlebarsHelper        | Helper name not in the registry                                 |
| ERR_6003 | HandlebarsHelperArgumentError  | Wrong argument count or type for a helper                       |

**Error message format:**

```
<Category> error: '<detail>' @ <file>:<line>:<col> (errno: ERR_NNNN)
  -> <one-line explanation>

   N-1 | <context line>
   N   | <error line>
       |  ^^^^^^^^^^^ <inline annotation>
   N+1 | <context line>

   <example of correct usage, if applicable>
   For more info, run: iidy explain ERR_NNNN
```

**Source metadata on every AST node:**

```pseudocode
type SrcMeta = { inputUri :: Text, start :: Position, end :: Position }
type Position = { line :: Int, column :: Int, offset :: Int }

-- Every AST constructor carries SrcMeta:
-- AstNull SrcMeta | AstBool Bool SrcMeta | AstNumber Scientific SrcMeta | ...
```

**Logic Flow:**

1. Tag resolution returns either an error (with position) or the resolved value.
2. Each error variant carries the four possible error categories: resolve errors,
   import errors, Handlebars errors, and cycle errors.
3. The enhanced error display maps the raw error to a user-facing message with
   context window, caret annotation, and example.

**Edge Cases:**

- Errors in the non-taken branch of `!$if` do not surface (lazy evaluation).
- Errors from custom resource expansion that cannot be attributed to a precise
  position use line 0, column 0 as a sentinel position.
- Import errors carry the import key name and resolved location, not a position
  in the source document.
- Handlebars errors are reported at the position of the containing templated
  string node.
- Cycle errors carry the path string of the detected cycle, not a position.

**Complexity Notes:**

Source position metadata must be attached to every AST node during parsing,
tracking line and column offsets through the YAML event stream. This ensures
that even deeply nested tag errors can report their precise source location.
The enhanced error display reads the original source text to extract the context
window, so the source must be retained through the pipeline.

---

## Supported CloudFormation Pass-Through Tags

The following 20 CloudFormation intrinsic function tags are recognized and
passed through after resolving their inner content:

| Tag             | CloudFormation Intrinsic  |
|-----------------|--------------------------|
| `!Ref`          | Ref                      |
| `!Sub`          | Fn::Sub                  |
| `!GetAtt`       | Fn::GetAtt               |
| `!Join`         | Fn::Join                 |
| `!Select`       | Fn::Select               |
| `!Split`        | Fn::Split                |
| `!Base64`       | Fn::Base64               |
| `!GetAZs`       | Fn::GetAZs               |
| `!ImportValue`  | Fn::ImportValue          |
| `!FindInMap`    | Fn::FindInMap            |
| `!Cidr`         | Fn::Cidr                 |
| `!Length`        | Fn::Length               |
| `!ToJsonString` | Fn::ToJsonString         |
| `!Transform`    | Fn::Transform            |
| `!ForEach`      | Fn::ForEach              |
| `!If`           | Fn::If (Condition)       |
| `!Equals`       | Fn::Equals               |
| `!And`          | Fn::And                  |
| `!Or`           | Fn::Or                   |
| `!Not`          | Fn::Not                  |

These tags are distinct from the `!$` preprocessing tags. Their inner content is
resolved through the preprocessing pipeline, but the tag itself is preserved in
the output YAML. Any unrecognized tag (not a `!$` preprocessing tag and not a
known CloudFormation tag) is preserved as-is with its inner content resolved.

---

## Testing Requirements

- All 24 custom tags (including `!$include` alias for `!$`, `!$string` alias
  for `!$toYamlString`, and `!$expand` for explicit template expansion) must
  have fixture tests with corresponding expected outputs.
- All error conditions must have fixture tests with corresponding expected error
  output snapshots.
- Error snapshot tests verify: error code (ERR_NNNN), file/line/column, caret
  annotation, and one-line explanation. They do not pin the example text or
  exact help string.
- YAML 1.1 compat behavior must be tested with `%YAML 1.1` directive, CFN
  auto-detected, and explicit `--yaml-spec 1.1` flag inputs.
- Handlebars helper tests must cover all 25 helpers including deprecated aliases.
- Property-based tests cover: word-splitting round-trip for case conversion
  helpers, base64 output character set, URL encoding never encoding unreserved
  characters.
- All tests run against mock/local fixtures. No real AWS calls.
- Test structure: one test group per tag or feature area; no monolithic test
  modules.

---

## Cross-References

- `docs/import-types.md` -- all supported import source types (`./file`,
  `ssm:`, `s3://`, `env:`, `git:`, `cfn:`, `http://`, `random:`)
- `docs/SECURITY.md` -- import security restrictions and path sandboxing
- `docs/requirements/01-cli-interface.md` -- `--yaml-spec`, `--format`, and
  `render` command spec
- `docs/requirements/03-import-system.md` -- import resolution, security model,
  cycle detection
- `docs/requirements/04-custom-resources.md` -- custom resource expansion
  pipeline (automatic expansion via `$params` registration)
- Rust oracle: `~/src/iidy/target/debug/iidy` (read-only reference binary)
- `DIVERGENCES.md` -- documented behavioral differences from Rust iidy
