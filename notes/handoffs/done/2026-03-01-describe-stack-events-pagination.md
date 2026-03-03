# Reconcile describe-stack --events Pagination Semantics -- Enhancement

**Status**: DONE
**Date**: 2026-03-01
**References**: `src/Iidy/Cfn/Operations/DescribeStack.hs`, Rust `src/cfn/describe_stack.rs`

## Context

Commit `7e04c3d` optimized event fetching to single-page for polling efficiency.
However, `describe-stack --events N` may need more than one page of events when
N exceeds the AWS page size (~100). Currently, if `--events 200` is requested,
only ~100 events from the first page are returned, with truncation info shown.

Rust paginates conditionally: it fetches pages until `all_events.len() >= N * 2`
or pages are exhausted. This ensures enough events for the requested count.

## Current Haskell Behavior

```haskell
-- In StackOperations.hs
fetchRecentStackEvents :: CfnContext -> Text -> IO [CF.StackEvent]
fetchRecentStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents { DEvents.stackName = Just sId }
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  pure $ fromMaybe [] resp.stackEvents
```

This returns at most ~100 events (one AWS page). The caller in DescribeStack.hs
then truncates to `numEvents` and shows truncation info.

## Rust Behavior

```rust
let mut all_events = first_events_resp.stack_events.unwrap_or_default();
let mut next_token = first_events_resp.next_token;
while next_token.is_some() && all_events.len() < event_count * 2 {
    // ... fetch next page, append ...
}
```

Rust fetches enough pages to have `event_count * 2` events, ensuring the
requested count is always satisfiable.

## Fix

### Option A: Conditional pagination (recommended)

Add a new function `fetchStackEventsUpTo` that paginates conditionally:

```haskell
fetchStackEventsUpTo :: CfnContext -> Text -> Int -> IO [CF.StackEvent]
fetchStackEventsUpTo ctx sId maxEvents = go Nothing []
  where
    target = maxEvents * 2  -- match Rust: fetch 2x requested
    go mToken acc
      | length acc >= target = pure acc
      | otherwise = do
          let req = DEvents.newDescribeStackEvents
                      { DEvents.stackName = Just sId
                      , DEvents.nextToken = mToken
                      }
          resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
          let events = fromMaybe [] resp.stackEvents
              acc'   = acc <> events
          case resp.nextToken of
            Nothing -> pure acc'
            Just tk -> go (Just tk) acc'
```

Use `fetchStackEventsUpTo` in `describeStack` when the user requests events.
Keep `fetchRecentStackEvents` (single-page) for polling loops — those only need
new events which always appear on page 1.

### Option B: Document as divergence and cap at 100

Keep single-page fetch. Document in DIVERGENCES.md that `--events N` for N > 100
shows at most ~100 events. This is simpler but means Haskell can't show full
event history for long-lived stacks.

**Recommendation**: Option A — matches Rust semantics and is a small change.

### DIVERGENCES.md Update

Replace the inaccurate "AWS API Pagination" section (lines 58-62) with:

```markdown
## describe-stack Event Pagination

**Cause**: Intentional optimization with conditional pagination.

Both implementations use single-page event fetches for polling loops (new events
always appear on the first page). For `describe-stack --events N`, Rust paginates
up to `N * 2` events to ensure the requested count is satisfiable. Haskell now
does the same via `fetchStackEventsUpTo`. The `list-stacks` command paginates
fully in both implementations.
```

## Codebase Reference

| What                       | Where                                               |
|----------------------------|-----------------------------------------------------|
| `describeStack`            | `src/Iidy/Cfn/Operations/DescribeStack.hs:51`      |
| `fetchRecentStackEvents`   | `src/Iidy/Cfn/StackOperations.hs:121`              |
| `buildEventsDisplay`       | `src/Iidy/Cfn/Operations/DescribeStack.hs:130`     |
| Rust describe_stack        | `~/src/iidy/src/cfn/describe_stack.rs` (read-only)  |
| DIVERGENCES.md             | `DIVERGENCES.md:58-62`                              |
| Optimization commit        | `7e04c3d`                                           |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Small function addition (fetchStackEventsUpTo), one call site change,
  and a DIVERGENCES.md text update.

## Progress

- [ ] Add `fetchStackEventsUpTo` to StackOperations.hs
- [ ] Wire into `describeStack` for event display (keep single-page for polling)
- [ ] Update DIVERGENCES.md (replace inaccurate pagination section)
- [ ] Build clean + all tests pass
