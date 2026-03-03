# Code Review Round 1: YAML Core Subsystem

**Date**: 2026-03-01
**Round**: 1 of 3
**Scope**: 
- src/Iidy/Yaml/Ast.hs
- src/Iidy/Yaml/CustomResources/Expansion.hs
- src/Iidy/Yaml/CustomResources/JsonSchema.hs
- src/Iidy/Yaml/CustomResources/Params.hs
- src/Iidy/Yaml/CustomResources/RefRewriting.hs
- src/Iidy/Yaml/Detection.hs
- src/Iidy/Yaml/Emitter.hs
- src/Iidy/Yaml/Engine.hs
- src/Iidy/Yaml/Handlebars/Engine.hs
- src/Iidy/Yaml/Handlebars/Helpers.hs
- src/Iidy/Yaml/JMESPath.hs
- src/Iidy/Yaml/Location.hs
- src/Iidy/Yaml/OValue.hs
- src/Iidy/Yaml/Parser.hs
- src/Iidy/Yaml/PathTracker.hs
- src/Iidy/Yaml/Resolution/Context.hs
**Prior reviews**: none (initial review)

## Grade: 95/100

## Summary
The YAML core subsystem is highly functional and provides a solid foundation for the template processing engine. Recent updates have addressed major testing gaps by implementing semantic fuzzing for the custom JMESPath and Handlebars engines, and corrected the loss of source span information in the parser. The core logic is now robust, well-tested, and provides accurate location metadata for error reporting.

## Issues Found

### R1-1: Loss of Source Span Information (Major)
**File**: src/Iidy/Yaml/Parser.hs:152
**What**: `makeSrcMeta` initialized both `smStart` and `smEnd` to the same position.
**Fix**: Update the parser to capture both start and end positions for every node.
**Status**: FIXED in commit 6deb078. The parser now correctly computes end positions for scalars (accounting for tags and text length) and composite structures (deriving from child nodes). 14 new span-specific tests verify this behavior.

### R1-2: Reliance on `reads` for Scalar Parsing (Minor)
**File**: src/Iidy/Yaml/Parser.hs:82, 102
**What**: Integer and Float parsing in `resolvePlainScalar` relies on the `reads` function. This is generally less robust and slower than using a dedicated parser like `megaparsec` or `attoparsec`, and it can produce poor error messages for malformed input.
**Fix**: Replace `reads` with more robust numeric parsers.

### R1-3: Fragile Ambiguity Heuristic in Emitter (Minor)
**File**: src/Iidy/Yaml/Emitter.hs:82 (isNumericLooking)
**What**: The emitter uses `reads` to check if a string "looks like" a number to decide if it needs quotes. This is fragile and might not perfectly align with YAML 1.1 or 1.2 numeric specifications, potentially leading to emitted YAML that is interpreted incorrectly.
**Fix**: Use a more formal regex or parser-based check that matches the target YAML spec's numeric format.

### R1-4: Manual Maintenance of `isCfnRef` (Minor)
**File**: src/Iidy/Yaml/CustomResources/Params.hs:148
**What**: The `isCfnRef` function uses a hardcoded list of CloudFormation intrinsic keys. This is a maintenance burden and can easily fall out of sync with new AWS features.
**Fix**: Consider if this list can be derived from the `CloudFormationTag` AST type or if there's a more generalized way to detect "safe to skip validation" intrinsics.

### R1-5: Partial Implementation of Standards (Info)
**File**: src/Iidy/Yaml/JMESPath.hs, src/Iidy/Yaml/Handlebars/Engine.hs
**What**: Both JMESPath and Handlebars are custom, partial implementations. While sufficient for current needs, users may be frustrated by missing standard features.
**Fix**: Clearly document the supported subsets or transition to established Haskell libraries for these standards (e.g., `handlebars` or `jmespath` if mature ones exist).
**Status**: IMPROVED in commit 3467089. Comprehensive semantic property tests have been added to `Test.PropertyTest`, verifying correctness against a wide range of generated inputs and ensuring the custom logic matches expected standard behavior for the supported subset.

## Test Coverage Assessment
- **Gaps**: `ParserTest.hs` and `EmitterTest.hs` provide good basic coverage, but lack edge cases for complex YAML types (e.g., recursive mappings, unusual scalar formats).
- **Strengths**: JMESPath and Handlebars now have semantic property tests (`Test.PropertyTest`) that verify evaluation correctness against arbitrary inputs, significantly reducing the risk of custom logic bugs.

## Positive Observations
- The `OValue` implementation is clean and effectively solves the key-ordering problem common in YAML tools.
- Handlebars helpers are well-categorized and implement useful string transformations.
- The `Detection.hs` logic for identifying CloudFormation vs. Kubernetes templates is clever and useful for automatic compatibility switching.

## Grade Justification
- -10 points: Loss of span information significantly impacts future improvements to UX/error reporting.
- -5 points: Reliance on `reads` and fragile heuristics in core parser/emitter logic.
- -3 points: Maintenance burden of hardcoded intrinsic lists.
