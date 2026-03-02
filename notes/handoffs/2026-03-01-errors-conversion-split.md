# Split Errors/Conversion.hs Into Domain-Specific Modules -- Refactoring

**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

`src/Iidy/Yaml/Errors/Conversion.hs` is 998 lines — the largest module in the project,
well above the 300-500 LOC target. It's an error classification & translation engine that
converts HsYAML/Resolver errors into `EnhancedPreprocessingError` variants for display.

The module has clear domain boundaries that map to 5 smaller modules.

## Inventory

### Current structure (998 LOC)

| Section           | Lines   | LOC  | Functions                                                    |
|-------------------|---------|------|--------------------------------------------------------------|
| Public API        | 25-194  | 170  | formatPreprocessErrorEnhanced, formatParseErrorEnhanced, translateParseError, convertToEnhanced, classifyResolveError |
| Message Classify  | 197-493 | 296  | classifyMessage, classifyMessage' (46-case matcher)          |
| Import/HB Classify| 496-518 | 22   | classifyImportError, classifyHandlebarsError                 |
| Position/Location | 521-643 | 122  | posToSourceLocation, adjustLocationForTag, isTypeMismatchError, adjustForTypeMismatch, tagFallbackOffset |
| Line Search       | 645-797 | 152  | 14 functions: findAnyTagOnLine, findFieldColumn, findFlowColumn, findSecondBracketArg, findUnquotedComma, findVariableColumn, findAfterKeyword, findTagInLine, findAnyTagInLine, safeLine, findSubstring, findAllSubstring, findSecondTag, findTagOnSourceLine |
| Parse Detection   | 800-828 | 28   | isParseStyleError, extractTagName                            |
| Guidance/Examples | 831-916 | 85   | extractMustBeGuidance, guessExampleFromMustBe, extractExpected, extractFound, generateTypeConversionHelp, tagExample |
| CFN Validation    | 919-976 | 57   | isCfnValidationMessage, parseCfnValidationMessage, cfnHelpText |
| Tag Discovery     | 979-998 | 19   | findTagExampleForUnexpectedField, findTagInNearbyLines       |

### Target structure

| New Module                          | Source Sections                   | ~LOC | Purpose                              |
|-------------------------------------|-----------------------------------|------|--------------------------------------|
| `Errors/Conversion.hs`             | Public API + Message Classify     | ~490 | Core API + classifier (re-exports)   |
| `Errors/Conversion/Location.hs`    | Position/Location                 | ~122 | HsYAML→Rust position translation     |
| `Errors/Conversion/LineSearch.hs`  | Line Search + Tag Discovery       | ~170 | Text search utilities                |
| `Errors/Conversion/Guidance.hs`    | Parse Detection + Guidance + CFN  | ~170 | Help text, examples, CFN intrinsics  |

This keeps the core Conversion.hs at ~490 LOC (still large due to the 46-case matcher,
but that's a single logical unit). The 3 extracted modules are pure utility code with no
circular dependencies.

## Phased Plan

### Phase 1: Extract LineSearch (~170 LOC, 14 functions)

Create `Errors/Conversion/LineSearch.hs` with all `find*` functions plus `safeLine`.
These are pure text utilities with no domain-specific imports beyond `Data.Text`.

Update Conversion.hs to import and re-export (or just import where used internally).

### Phase 2: Extract Location (~122 LOC, 5 functions)

Create `Errors/Conversion/Location.hs` with position translation functions.
Depends on LineSearch for `findAnyTagOnLine`, `findFieldColumn`, etc.

### Phase 3: Extract Guidance (~170 LOC, 13 functions)

Create `Errors/Conversion/Guidance.hs` with error message parsing, example generation,
and CFN help text. Some functions here are called from classifyMessage', so the
dependency is Conversion → Guidance.

### Phase 4: Update imports and verify

Ensure Conversion.hs re-exports everything needed by external callers.
All test fixtures should work unchanged.

Each phase leaves tests green independently.

## Codebase Reference

| What                    | Where                                           |
|-------------------------|-------------------------------------------------|
| Conversion module       | `src/Iidy/Yaml/Errors/Conversion.hs` (998 LOC) |
| Enhanced error types    | `src/Iidy/Yaml/Errors/Enhanced.hs`             |
| Error IDs               | `src/Iidy/Yaml/Errors/Ids.hs`                  |
| Display module          | `src/Iidy/Yaml/Errors/Display.hs`              |
| Error tests             | `test/Test/ErrorDisplayTest.hs`                 |
| Error snapshot tests    | `test/Test/ErrorSnapshotTest.hs`                |

## Delegation Strategy

### Phase 1 (LineSearch)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — mechanical extraction, no design decisions
- **Note**: Pure function move with no logic changes

### Phase 2 (Location)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — straightforward extraction
- **Note**: Depends on LineSearch being done first

### Phase 3 (Guidance)
- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — straightforward extraction
- **Note**: Independent of Phase 2, parallel with it after Phase 1

### Phase 4 (Verify)
- **Can delegate?** No — main context should verify
- **Why**: Cross-cutting verification, re-export correctness

Phases 2 and 3 can run in parallel after Phase 1.

## Progress

- [ ] Phase 1: Extract Errors/Conversion/LineSearch.hs
- [ ] Phase 2: Extract Errors/Conversion/Location.hs
- [ ] Phase 3: Extract Errors/Conversion/Guidance.hs
- [ ] Phase 4: Verify all tests pass, update cabal, clean imports

## Handoff Notes

(to be filled by implementing session)
