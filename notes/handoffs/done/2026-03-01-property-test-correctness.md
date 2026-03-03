# Enhance PropertyTest Correctness -- Feature Enhancement

**Status**: DONE
**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

`test/Test/PropertyTest.hs` has 22 property tests + 6 fuzz groups, but they primarily
test **no-crash safety** and **output format** (hex length, base64 padding, etc.).
Missing: semantic correctness properties for JMESPath evaluation and Handlebars helpers.

Current coverage: 2/11 JMESPath expression types (18%), 6/27 Handlebars helpers (22%).

## Key Architecture Decisions

- JMESPath: custom implementation in `src/Iidy/Yaml/JMESPath.hs` (~600 LOC)
  - `applyJmesPath :: Text -> Value -> Either JMESPathError Value`
  - Supports: field, index, wildcard, projection, flatten, filter, multi-select, pipe, comparison, not
- Handlebars: custom implementation in `src/Iidy/Yaml/Handlebars/`
  - `interpolate :: Map Text HelperFn -> Value -> Text -> Either InterpolateError Text`
  - 27 helpers: 8 case, 6 string manipulation, 3 encoding, 4 serialization, 2 comparison/lookup
  - Block helpers: if, each, with, unless

## Chunks

### Chunk 1: JMESPath Semantic Properties

Add correctness properties to existing `jmesPathPropertyTests` group:

```haskell
-- Algebraic laws
prop_jmespath_pipe_identity    -- @ | @ = @
prop_jmespath_field_object     -- {key: val}.key = val (for generated key/val)
prop_jmespath_index_bounds     -- arr[i] where 0<=i<len = arr !! i
prop_jmespath_negative_index   -- arr[-i] = arr[len-i] for valid i
prop_jmespath_index_oob        -- arr[i] where i>=len = Null
prop_jmespath_wildcard_array   -- [*] on array = identity
prop_jmespath_filter_true      -- [?`true`] on array = array
prop_jmespath_filter_false     -- [?`false`] on array = []
prop_jmespath_comparison_refl  -- x == x is true for all x
prop_jmespath_not_involution   -- !!x = x (boolean context)
prop_jmespath_multiselect_keys -- {a: @, b: @} always has keys {a, b}
```

### Chunk 2: Handlebars Helper Correctness

Add properties for untested helpers:

```haskell
-- Case helpers
prop_toUpperCase_idempotent   -- toUpperCase(toUpperCase(x)) = toUpperCase(x)
prop_camelCase_noSpaces       -- camelCase output has no spaces/underscores/hyphens
prop_pascalCase_startsUpper   -- pascalCase output starts with uppercase

-- String manipulation
prop_trim_idempotent          -- trim(trim(x)) = trim(x)
prop_length_nonneg            -- length(x) >= 0
prop_concat_associative       -- concat(a,b,c) = a ++ b ++ c

-- Encoding
prop_sha256_deterministic     -- sha256(x) == sha256(x) for same input
prop_sha256_different_inputs  -- sha256(x) != sha256(y) for x != y (probabilistic)
prop_base64_decodable         -- base64(x) is valid base64 (decode succeeds)
prop_urlEncode_safe_chars     -- urlEncode preserves alphanumerics

-- Serialization
prop_toJson_parseable         -- toJson(x) is valid JSON (decode succeeds)
prop_toYaml_parseable         -- toYaml(x) is valid YAML (parse succeeds)
```

### Chunk 3: Composition & Round-trip Properties

```haskell
-- JMESPath composition
prop_jmespath_field_chain     -- a.b on {a: {b: v}} = v
prop_jmespath_projection_map  -- [*].field on [{field: v}...] = [v...]

-- Handlebars integration
prop_handlebars_nested_helpers -- helpers can be composed without crash
prop_handlebars_block_if_true  -- {{#if true}}X{{/if}} = "X"
prop_handlebars_each_length    -- {{#each arr}}x{{/each}} length = len(arr)
```

## Codebase Reference

| What                  | Where                                       |
|-----------------------|---------------------------------------------|
| PropertyTest          | `test/Test/PropertyTest.hs` (~483 lines)    |
| JMESPath evaluator    | `src/Iidy/Yaml/JMESPath.hs`                |
| JMESPath types        | `src/Iidy/Yaml/JMESPath/Types.hs`          |
| Handlebars engine     | `src/Iidy/Yaml/Handlebars/Engine.hs`       |
| Handlebars helpers    | `src/Iidy/Yaml/Handlebars/Helpers.hs`      |
| Existing generators   | `test/Test/PropertyTest.hs` (Arbitrary instances) |

## Delegation Strategy

### Chunk 1 (JMESPath)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — clear spec, follows existing pattern
- **Note**: Need to import `applyJmesPath` and construct `Value` inputs

### Chunk 2 (Handlebars)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — mechanical addition of properties
- **Note**: Need to call individual helpers or use `interpolate` with template strings

### Chunk 3 (Composition)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — follows patterns from chunks 1-2

All three chunks are independent and can run in parallel worktrees.

## Progress

- [ ] Chunk 1: JMESPath semantic properties (~11 tests)
- [ ] Chunk 2: Handlebars helper correctness (~12 tests)
- [ ] Chunk 3: Composition & round-trip (~5 tests)
- [ ] Final: all tests pass, zero warnings

## Handoff Notes

(to be filled by implementing session)
