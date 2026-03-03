# Fix Loss of Source Span Information -- Feature Enhancement

**Status**: DONE
**Date**: 2026-03-01
**Session**: `00cdf3e0-e600-42b8-8b73-07f9dcd707ad`

## Context

`makeSrcMeta` in `src/Iidy/Yaml/Parser.hs:173-174` initializes both `smStart` and `smEnd`
to the same position:

```haskell
makeSrcMeta :: Text -> Y.Pos -> SrcMeta
makeSrcMeta uri pos = SrcMeta uri (convertPos pos) (convertPos pos)
```

This means AST nodes have zero-width spans, which prevents the error display subsystem from
accurately highlighting the full extent of problematic content with carets.

## SrcMeta Type

```haskell
-- src/Iidy/Yaml/Ast.hs:43-48
data SrcMeta = SrcMeta
  { smInputUri :: !Text
  , smStart    :: !Position  -- ^ Start position
  , smEnd      :: !Position  -- ^ End position (currently == smStart)
  }
```

## The Problem

HsYAML's event-based API provides `Y.Pos` at the START of each node, but not the end
position. The parser receives events like `MappingStart`, `MappingEnd`, `ScalarValue`, etc.
with positions for the start of each event.

To get proper spans, options are:

### Option A: Track end positions from subsequent events

When building AST nodes, the END position of a node is approximated by the START position
of the next sibling or parent-end event. This requires a post-processing pass or threading
the "next position" through the parser state.

### Option B: Post-processing pass over AST

After parsing, walk the AST and infer end positions:
- For scalars: `smEnd = smStart + length(serialized value)`
- For mappings/sequences: `smEnd = max(smEnd of last child)`
- For tags: `smEnd = smStart + length(tag name + content)`

### Option C: Use HsYAML's position from end events

HsYAML emits `MappingEnd`, `SequenceEnd` events with their own positions. If the parser
captures these, it can use them as `smEnd` for the corresponding node.

## Recommendation

**Option C** is most accurate. The parser in `Parser.hs` processes HsYAML events via
a state machine — the `MappingEnd`/`SequenceEnd` events already flow through but their
positions are currently discarded. Capturing them requires threading end-position back
to the node being constructed.

For scalars, the end position should be `start + length(value)` since there's no
separate end event.

## Codebase Reference

| What                 | Where                                          |
|----------------------|-------------------------------------------------|
| makeSrcMeta          | `src/Iidy/Yaml/Parser.hs:173-174`              |
| SrcMeta type         | `src/Iidy/Yaml/Ast.hs:43-48`                   |
| Position type        | `src/Iidy/Yaml/Location.hs:10-14`              |
| Parser state machine | `src/Iidy/Yaml/Parser.hs` (full file)          |
| Error display (caret)| `src/Iidy/Yaml/Errors/Display.hs`              |
| convertPos           | `src/Iidy/Yaml/Parser.hs:155-160`              |

## Delegation Strategy

- **Can delegate?** Partially — research and option prototyping yes, but the parser is complex
- **Sub-agent type**: Opus — requires deep understanding of HsYAML event stream and parser state
- **Risk**: Parser changes can break error position alignment (49 error snapshots)

## Progress

- [x] Research HsYAML event positions (MappingEnd, SequenceEnd, ScalarValue)
- [x] Implement span computation (hybrid of Option B + C approach)
- [x] Replace makeSrcMeta with makeScalarMeta + childrenEndPos
- [x] Verify error snapshots still pass (48/49 pass, 1 pre-existing failure)
- [x] Test with multi-line mapping/sequence nodes (14 new span tests)

## Handoff Notes

### Implementation (2026-03-01)

**Approach**: The HsYAML high-level `Loader` API does NOT expose `MappingEnd`/`SequenceEnd`
positions to callbacks -- those events are consumed internally. Pure Option C would require
rewriting the parser to use the low-level `parseEvents` API, which was too risky.

Instead, implemented a **hybrid of Option B** within the existing Loader callbacks:
- **Scalars**: `makeScalarMeta` computes `smEnd = smStart + tagLen + textLen`
  - Accounts for tag prefix (e.g., "!Ref " = 5 chars) when present
  - Accurate for single-line scalars; approximate for multi-line (posLine stays same)
- **Sequences**: `childrenEndPos` returns `smEnd` of last child element
- **Mappings**: `childrenEndPos` returns `smEnd` of last value in pair list
- **Empty collections**: Fall back to start position (zero-width, same as before)

**Key findings**:
- `makeSrcMeta` was removed entirely (unused after changes)
- `foldl'` is in Prelude on GHC 9.10.3 (base 4.20), no `Data.List` import needed
- Error display system (`formatSourceContext`) does NOT currently use `smEnd` --
  caret widths are hardcoded per error type. The span info is now correct in the AST
  for future use.
- All 49 error snapshot tests unaffected (48 pass, 1 pre-existing wording diff)
- All 37 render snapshot tests unaffected (35 pass, 2 pre-existing failures)
- 14 new span-specific tests added, 972 total tests pass

**Commit**: `6deb078` — Fix zero-width source spans in YAML parser
