# Code Review 1b: YAML Resolver & Error Subsystem

**Date**: 2026-02-28
**Scope**: Resolver.hs, Context.hs, Conversion.hs, Enhanced.hs, Display.hs, Ids.hs + tests

## Summary

The resolver is well-structured with clean separation between YAML resolution, error classification, and error display. The use of structured `ResolveErrorKind` to avoid downstream string-parsing is a strong design choice. The error display system faithfully reproduces Rust's output format with proper ANSI coloring, source context, and caret pointing.

The main concerns are: (1) a repeated bug in CFN validation error messages where the wrong value is displayed, (2) dead code in Context.hs, (3) an O(n^2) list append in resource expansion, and (4) significant test coverage gaps -- 14 of 22 preprocessing tag resolvers and all CFN validation have zero dedicated tests. Conversion.hs is very large (~1000 LOC) and relies heavily on string pattern matching, but this is a conscious design for Rust compatibility and the structured-kind path mitigates the fragility.

## Critical Issues

### BUG-1: Wrong value shown in CFN validation error messages (Resolver.hs lines 346, 363, 371)
**Severity**: Critical
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Resolver.hs`

In the `validateCfnTag` function, three patterns for 2-element arrays where the first element has the wrong type use `oValueTypeName val` for the second element instead of the actual second element. `val` is bound to the *entire array* from the outer case expression, not the second element.

**Line 346** (`!Sub`):
```haskell
OArray [v, _] -> cfnValidationError meta "!Sub" $
  "!Sub array form expects [string, object], found ["
  <> oValueTypeName v <> ", " <> oValueTypeName val <> "]"
--                                           ^^^ BUG: val is the whole array, not the 2nd element
```

This produces messages like `found [number, sequence]` instead of `found [number, string]`. The wildcard `_` discards the second element.

**Same bug on line 363** (`!Join`) and **line 371** (`!Select`).

**Fix**: Bind the second element and use it:
```haskell
OArray [v, v2] -> cfnValidationError meta "!Sub" $
  "... found [" <> oValueTypeName v <> ", " <> oValueTypeName v2 <> "]"
```

## Major Issues

### DEAD-1: `VariableSource` type is completely unused (Context.hs lines 20-27)
**Severity**: Major
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Context.hs`

The `VariableSource` type and its five constructors (`SourceLocalDefs`, `SourceImportedDocument`, `SourceTagBinding`, `SourceBuiltIn`, `SourceExternal`) are defined and exported but never imported or used anywhere in the codebase. This is dead code.

### DEAD-2: `withInputUri` function is never used (Context.hs lines 51-52)
**Severity**: Major
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Context.hs`

The function `withInputUri` is exported but never called outside its defining module. The resolver sets `tcInputUri` directly via record update syntax in `resolveExpand` (line 799) and `buildReparse` (line 262). This function is dead code.

### PERF-1: O(n^2) list append in resource expansion fold (Resolver.hs lines 231-232)
**Severity**: Major
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Resolver.hs`

Inside `expandResources`, the fold body uses `acc ++ erResources expansionResult` and `acc ++ [(resName, resVal)]`. Each `++` traverses the entire accumulated list, making this O(n^2) in the number of resources. For CloudFormation templates with hundreds of resources, this could be noticeably slow.

**Fix**: Accumulate in reverse order and reverse at the end, or use a difference list (`DList`).

### STRUCT-1: Conversion.hs is ~1000 LOC with heavy string pattern matching (Conversion.hs)
**Severity**: Major
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Errors/Conversion.hs`

At ~1000 lines, this module exceeds the project's 300-500 LOC guideline. The `classifyMessage'` function (lines 202-493) is a single function with ~290 lines of guard clauses doing string prefix/suffix/infix matching. While the structured `ResolveErrorKind` path in `classifyResolveError` mitigates this (string matching only fires for `REGeneric`), the fallback path is fragile and hard to maintain.

Possible split: extract `cfnHelpText`, `tagExample`, `extractMustBeGuidance`, `guessExampleFromMustBe`, and the location-adjustment functions into a separate `Conversion.Helpers` module.

### DEAD-3: Dead branch in `resolveDotPathO` (Resolver.hs line 511)
**Severity**: Minor (upgraded to Major due to misleading code)
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Resolver.hs`

```haskell
let segments = T.splitOn "." path
in case segments of
  [] -> Nothing          -- <-- This branch is unreachable
  (root:rest) -> ...
```

`T.splitOn "." ""` returns `[""]`, never `[]`. `T.splitOn` with a non-empty separator always returns at least one element. The `[]` branch is dead code that gives a false sense of safety.

## Minor Issues

### STYLE-1: Misleading underscore prefix on used parameter (Resolver.hs line 110)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Resolution/Resolver.hs`

```haskell
cfnValidationError meta _tagName detail =
  Left (ResolveError (smStart meta) detail (RECfnValidation _tagName))
```

The parameter `_tagName` is actually used in the body (passed to `RECfnValidation`). The underscore prefix conventionally signals an unused binding. Rename to `tagName`.

### STYLE-2: `oValuesEqual` is redundant (OValue.hs lines 87-89)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/OValue.hs`

```haskell
oValuesEqual :: OValue -> OValue -> Bool
oValuesEqual (ONumber a) (ONumber b) = a == b
oValuesEqual a b = a == b
```

Since `OValue` derives `Eq` and `Scientific` has a correct `Eq` instance, the special `ONumber` case is equivalent to the general case. This function is equivalent to `(==)`.

### STYLE-3: Duplicated code in "must be a mapping" / "must be a sequence" branches (Conversion.hs lines 319-350)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Errors/Conversion.hs`

The two guard branches for `"must be a mapping"` and `"must be a sequence"` (lines 319-333 and 336-350) are structurally identical -- they differ only in the guard condition text. These could be merged into a single branch:

```haskell
| "must be a mapping" `T.isPrefixOf` msg || "must be a sequence" `T.isPrefixOf` msg =
    ...
```

### STYLE-4: `findTagExampleForUnexpectedField` uses odd line offset (Conversion.hs line 982)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Errors/Conversion.hs`

```haskell
case findTagOnSourceLine allLines (loc { srcLocLine = max 1 (lineNum - 3) }) of
```

This searches for a tag at line `lineNum - 3`, which is somewhat arbitrary and may find the wrong tag if there are multiple tags nearby. The function then falls back to `findTagInNearbyLines` which searches `lineNum - 5` through `lineNum`, which overlaps. The search strategy could be simplified.

### STYLE-5: `findUnquotedComma` does not handle escape sequences (Conversion.hs lines 705-714)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Errors/Conversion.hs`

The `findUnquotedComma` function tracks double-quote state but does not handle backslash-escaped quotes (`\"`). If a YAML value contains `"a\"b,c"`, the function would incorrectly identify the comma as unquoted. In practice, this is only used for error position calculation (not correctness), so the impact is limited to potentially pointing at the wrong column.

### STYLE-6: Import error always classified as `ImportFileNotFound` (Conversion.hs line 500)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Errors/Conversion.hs`

```haskell
classifyImportError filePath (ImportError msg) =
  let loc = SourceLocation filePath 0 0 ""
  in YamlSyntaxError YamlSyntaxInfo
    { ysiErrorId = ImportFileNotFound, ... }
```

All import errors are classified as `ImportFileNotFound` regardless of the actual error (URL unreachable, auth failure, circular dependency, etc.). The `ErrorId` type has `ImportUrlUnreachable`, `ImportAuthenticationFailure`, `ImportCircularDependency`, etc., but none are used for import error classification. The `msg` field is not examined to pick a more specific ID.

### STYLE-7: Location with line=0, column=0 produces odd display (Display.hs + Conversion.hs)
**Severity**: Minor
**File**: `/home/tavis/src/iidy-hs/src/Iidy/Yaml/Errors/Display.hs`

When `srcLocLine` is 0 (as in `classifyImportError` and `classifyHandlebarsError`), `formatSourceContext` shows: no previous line, no current line, and line 1 as the "next line". This means the first source line appears in context even though the error position is unknown. It would be cleaner to show no source context at all when the line number is 0.

## Test Coverage Assessment

### Major gaps in ResolverTest.hs

The resolver has 22 preprocessing tag types but only 11 have dedicated test groups. The following tags have **zero dedicated tests**:

| Tag               | Resolver function       | Status    |
|-------------------|------------------------|-----------|
| `!$concat`        | `resolveConcat`        | Untested  |
| `!$concatMap`     | `resolveConcatMap`     | Untested  |
| `!$mergeMap`      | `resolveMergeMap`      | Untested  |
| `!$eq`            | `resolveEq`            | Indirect only (used as filter in map test) |
| `!$not`           | `resolveNot`           | Untested  |
| `!$escape`        | `resolveEscape`        | Untested  |
| `!$expand`        | `resolveExpand`        | Untested  |
| `!$parseYaml`     | `resolveParseYaml`     | Untested  |
| `!$parseJson`     | `resolveParseJson`     | Untested  |
| `!$toYamlString`  | `resolveToYamlString`  | Untested  |
| `!$toJsonString`  | `resolveToJsonString`  | Untested  |
| `!$mapValues`     | `resolveMapValues`     | Untested  |
| Template strings  | `resolveTemplateString`| Untested  |

### No CFN validation tests

`validateCfnTag` has extensive validation logic for 10+ CloudFormation intrinsic functions with multiple error paths each. None of these are tested. This is where BUG-1 hides -- tests would have caught the wrong-value-in-error-message bug.

### ErrorClassificationTest.hs coverage is good

The error classification tests cover the major branches well: unknown tags, unexpected fields, variable not found, property not found, type mismatch, CFN validation, missing fields, handlebars errors, JMESPath errors, parse errors, and the fallback path. Location preservation is also tested.

### ErrorIdTest.hs coverage is strong

Round-trip testing (`errorIdFromCode . errorIdCode == Just`), uniqueness, exhaustiveness check, and format validation are all present. The exhaustiveness check (comparing range scan against list length) is a clever way to catch missing entries.

### Missing edge case tests

- `expandBrackets` with a variable that resolves to a value containing `[` (potential recursion beyond depth limit)
- `resolveDotPathO` with empty path `""`
- `findMissingTemplateVar` with nested/escaped handlebars `{{{var}}}`
- `deduplicateResources` with key collision ordering
- `mergeOObjects` with empty base or overlay

## Positive Observations

1. **Structured error kinds are excellent**. The `ResolveErrorKind` ADT captures semantic error information at the point of creation, avoiding fragile downstream string parsing. The fallback to string matching only for `REGeneric` is a clean escape hatch.

2. **Error display format is thorough**. The `formatSourceContext` function handles edge cases well: out-of-range line numbers, zero-width spans, column clamping to line length. The gutter padding matches Rust's `{:4}` format precisely.

3. **`ErrorId` system is well-designed**. Unique numeric codes with round-trip testing, exhaustiveness checks, and clear categorical ranges (1xxx-9xxx) make this maintainable and extensible.

4. **Bracket expansion has a depth limit**. The `expandBrackets` function limits recursion to 10 iterations, preventing infinite loops from circular variable references like `x = "[x]"`.

5. **`TagContext` is simple and correct**. The immutable context with `withVariable` / `withBindings` producing new contexts (not mutating) makes scoping rules easy to reason about. The `Map.union` in `withBindings` correctly gives new bindings precedence over existing ones.

6. **Test helpers are well-factored**. The `assertResolves`, `assertResolveFails`, `assertResolveFailsWith` helpers in ResolverTest.hs, along with the AST builder shortcuts (`str`, `num`, `bool`, `seq_`, `map_`, `ppTag`), make tests concise and readable.

7. **CFN validation is comprehensive**. The `validateCfnTag` function covers all CloudFormation intrinsic functions with specific, helpful error messages including expected vs found types and element counts.

## Grade: B-

The code is structurally sound with good separation of concerns and a strong error classification design. The structured `ResolveErrorKind` is a highlight. However, the critical BUG-1 (wrong value in CFN error messages) affects correctness, the test coverage gap is substantial (14 untested resolver paths, zero CFN validation tests), and there is non-trivial dead code. The Conversion.hs module exceeds the project's LOC guidelines. These issues collectively prevent a higher grade, but the foundation is solid and the issues are all fixable.
