# Unknown Import Prefix Should Error, Not Fall Through -- Bug Fix

**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`
**References**: Rust source `~/src/iidy/src/yaml/imports/mod.rs:241-247`

## Context

`parseTypePrefix` in `Iidy.Yaml.Imports.Types` silently treats unknown prefixes
(e.g. `bogus:x`) as plain file paths by returning `("", loc)`. The Rust version
errors with `"Unknown import type '{}' in {}"`. This is a feature-completeness
divergence and a usability issue: typos in import prefixes silently resolve as
file paths instead of flagging the mistake.

## Issue

| What                    | Where                                             |
|-------------------------|---------------------------------------------------|
| `parseTypePrefix`       | `src/Iidy/Yaml/Imports/Types.hs:82-93`            |
| `parseImportType`       | `src/Iidy/Yaml/Imports/Types.hs:55-80`            |
| Only caller (dispatch)  | `src/Iidy/Yaml/Imports/Loaders/Dispatch.hs:34-37` |
| Existing test (wrong)   | `test/Test/SecurityControlsTest.hs:85-89`          |
| Rust equivalent         | `~/src/iidy/src/yaml/imports/mod.rs:241-247`       |

### Fix

1. **`parseTypePrefix`** (line 89): Change the unknown-prefix fallthrough from
   `("", loc)` to returning an error. Since `parseTypePrefix` currently returns
   `(Text, Text)`, the cleanest approach is to make `parseImportType` do the
   error check after calling `parseTypePrefix`. When `parseTypePrefix` returns
   `("", loc)` AND `loc` contains a `:` with a non-empty prefix before it,
   that means an unknown prefix was found — error with
   `"Unknown import type '<prefix>' in <location>"`.

   Alternatively, change `parseTypePrefix` return type to `Either ImportError (Text, Text)`.

2. **Test** (line 85-89): Update the existing test to expect `Left (ImportError ...)`
   instead of `Right ImportFile`.

3. **Add a test**: Ensure that things like `./foo:bar` (colon in filename after
   `./` prefix) still work as file paths — the colon check should only apply
   when the colon-split produced a non-empty prefix that wasn't in `knownTypes`.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet — isolated, clear spec, single module + test
- **Why**: Mechanical fix with clear before/after behavior

## Progress

- [ ] Fix `parseImportType` to error on unknown prefixes
- [ ] Update existing test to expect error
- [ ] Add regression test for colon-in-filename paths
- [ ] Build clean, all tests pass

## Handoff Notes

(to be filled by implementing session)
