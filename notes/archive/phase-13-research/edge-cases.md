# Edge Cases: Detailed Analysis

## 1. Changeset Name Generation

| | Rust | Haskell | Match? |
|---|------|---------|--------|
| Default name | Docker-style random (`generate_dashed_name()`, e.g. "brave-cat") | Hardcoded `"changeset"` | **NO** |
| User-provided | Used as-is | Used as-is | YES |
| Collision handling | None (relies on unique random names) | None (will fail on repeated runs) | **NO** |
| REVIEW_IN_PROGRESS | Detects existing changeset, returns its details | No detection | **NO** |

**Rust code**: `~/src/iidy/src/cfn/changeset_operations.rs` lines 114-142
**Haskell code**: `app/Main.hs` line 116: `let csName = maybe "changeset" id (ccsChangesetName args)`

**Impact**: If a user runs create-changeset twice without specifying a name, Haskell will fail
on the second call because "changeset" already exists. Rust generates a fresh random name each time.

**Fix**: Port `generate_dashed_name()` or use UUID-based names when user doesn't specify.

## 2. delete-stack When Deletion Already In Progress

| State | Rust | Haskell | Match? |
|-------|------|---------|--------|
| DELETE_IN_PROGRESS | Proceeds (AWS idempotent) | Proceeds (AWS idempotent) | YES |
| DELETE_COMPLETE | Treats as absent, shows StackAbsentInfo | Treats as absent, returns 0 silently | **NO** (display) |
| DELETE_FAILED | Treats as existing, attempts delete | Treats as existing, attempts delete | YES |

**Haskell stackExists** (`StackOperations.hs:62-68`):
```haskell
stackExists ctx sName = do
  mStack <- getStack ctx sName
  pure $ case mStack of
    Nothing -> False
    Just s  -> s.stackStatus /= CF.StackStatus_DELETE_COMPLETE
```

The core logic matches. The divergence is in display — Rust shows StackAbsentInfo with
STS context, Haskell silently returns 0. Already tracked in delete-stack.md.

## 3. watch-stack Inactivity Timeout — **NOT IMPLEMENTED**

**Haskell** (`WatchStack.hs:60`): `_timeoutSeconds` parameter is underscored and unused.

**Rust** (`watch_stack.rs:243-312`):
- Tracks `last_event_time = chrono::Utc::now()`
- Updates on each new event batch
- Checks `(now - last_event_time) > inactivity_timeout`
- Default: 180 seconds (from CLI, `cli.rs:478`)
- On timeout: emits `InactivityTimeoutInfo`, exits polling loop

**Fix needed**:
1. In `pollForCompletion` or `watchStack`, track time of last event
2. After each poll with no new events, check if timeout exceeded
3. If exceeded, return with timeout status
4. Emit `OdInactivityTimeout` (renderer already handles this — Interactive.hs:722)

## 4. Overall Poll Timeout

| | Rust | Haskell |
|---|------|---------|
| Default | 3600 seconds (1 hour) | None |
| Configurable | Yes | `pcTimeoutSeconds :: Maybe Int` exists but unused |

**Haskell**: `PollConfig` has `pcTimeoutSeconds` field but `pollForCompletionWith` never checks it.
This means operations could poll forever if a stack never reaches a terminal state (e.g., stuck
in UPDATE_IN_PROGRESS due to a resource that never completes).

**Fix**: Add timeout check in `pollForCompletionWith` loop. Compare elapsed time against
`pcTimeoutSeconds`.

## 5. Terminal States Consistency

**Haskell terminal states by command**:

| Command | States | Count |
|---------|--------|-------|
| CreateStack | 14 (includes DELETE_SKIPPED, REVIEW_IN_PROGRESS) | 14 |
| UpdateStack | 14 (same as CreateStack) | 14 |
| DeleteStack | 6 (DELETE_COMPLETE/FAILED + failure states) | 6 |
| WatchStack | 13 (no DELETE_SKIPPED, no REVIEW_IN_PROGRESS) | 13 |
| Changeset | 12 (no DELETE_SKIPPED, no REVIEW_IN_PROGRESS) | 12 |

**Rust**: ALL commands use the SAME terminal state list from `is_terminal_status.rs`.
The detection is event-based — looks for the main stack resource reaching a terminal status.

**Divergence**: Haskell has different terminal state lists per command. This is mostly
harmless (extra states just mean "stop polling if you see this"), but could cause issues
if a state is missing from a list where it's needed.

**Specific concern**: DeleteStack's list doesn't include `UPDATE_COMPLETE` or `IMPORT_COMPLETE`.
If somehow a delete triggers an update event (shouldn't happen), it would poll forever.
In practice this is unlikely, but Rust's approach of using one universal list is safer.

## 6. Previous Events Count

| Command | Rust | Haskell | Match? |
|---------|------|---------|--------|
| describe-stack | `--events` arg, default 50 | `--events` arg, default 50 | YES |
| watch-stack | 10 (`DEFAULT_PREVIOUS_EVENTS_COUNT`) | All events (no limit) | **NO** |
| delete-stack | 10 (pre-confirmation) | 0 (not shown) | **NO** (missing feature) |
| exec-changeset | 10 | 0 (not shown) | **NO** (missing feature) |
| create-stack | Not shown separately | Not shown | YES |
| update-stack | Not shown separately | Not shown | YES |

**Rust**: `DEFAULT_PREVIOUS_EVENTS_COUNT = 10` in `constants.rs:8`
**Haskell**: `defaultPreviousEventsCount = 10` in `Constants.hs:21` — exists but not used
by watch-stack, delete-stack, or exec-changeset.

**Fix**: When adding previous events display to watch-stack/delete-stack/exec-changeset,
use `defaultPreviousEventsCount` (10) to limit the display.

## 7. Event Duration Calculation

Rust shows duration on the final stack event, e.g. `CREATE_COMPLETE (3s)`.
The `StackEventWithTiming` type has `sewDurationSeconds :: Maybe Int`.

**Haskell**: The type exists but durations are always `Nothing` when constructing events:
```haskell
StackEventWithTiming { sewEvent = e, sewDurationSeconds = Nothing }
```

This is used in CreateStack.hs:88, UpdateStack.hs:111, DeleteStack.hs:96, Changeset.hs:168.

**Rust**: Calculates duration from first event to terminal event for the main stack resource.
Source: `watch_stack.rs` `calculate_event_timing()`.

**Fix**: Calculate duration by comparing timestamps of first and last events for the
main stack resource. Set `sewDurationSeconds` on the terminal event.

## 8. create-or-update with ROLLBACK_COMPLETE Stack

**Verified**: Rust's `check_stack_exists` (`changeset_operations.rs:80-99`) does NOT
filter by status — returns `true` for any stack that `DescribeStacks` returns. It does
NOT have special ROLLBACK_COMPLETE handling either. Both versions will dispatch to update
and fail with an AWS error.

However, AWS `DescribeStacks` by name does NOT return `DELETE_COMPLETE` stacks, so those
are implicitly excluded. Haskell's explicit `!= DELETE_COMPLETE` check is a safety net.

**Both versions have the same behavior for ROLLBACK_COMPLETE.** No divergence.

## 9. Event Pagination (fetchStackEvents)

**Both Rust and Haskell fetch only one page** of `DescribeStackEvents`. Neither paginates.

**Rust** (`stack_operations.rs:215-224`):
```rust
let resp = client.describe_stack_events().stack_name(stack_name).send().await?;
let mut events = resp.stack_events.unwrap_or_default();
```

**Haskell** (`StackOperations.hs:75-80`):
```haskell
fetchStackEvents ctx sId = do
  let req = DEvents.newDescribeStackEvents { DEvents.stackName = Just sId }
  resp <- runResourceT $ Amazonka.send (cfnEnv ctx) req
  pure $ fromMaybe [] resp.stackEvents
```

AWS returns most recent events first, single page is usually sufficient.
**No divergence here.**

## 10. Client Request Token Handling

Rust generates a unique client request token for each operation and tracks derived
tokens for changeset operations. This ensures idempotency — if the same operation
is retried, AWS recognizes the token and returns the original result.

**Haskell**: Generates a UUID token (`generateToken` in Main.hs:324-338) and passes
it through, but:
- `ctxDeriveToken` exists for deriving changeset tokens — verify it's used correctly
- Token is passed to `buildCreateStackRequest` etc. — verify it's included in the API call

This is important for safety: without proper token handling, retrying a failed
create-stack could create duplicate stacks.
