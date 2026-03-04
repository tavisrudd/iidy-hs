# Bug: watch-stack exits immediately on already-terminal stacks

**Date**: 2026-03-02
**Purpose**: Fix watch-stack (and other event-watching commands) to ignore pre-existing terminal status and wait for NEW events.

---

## Context

When `watch-stack` is run against a stack already in a terminal state (e.g. `CREATE_COMPLETE`), it exits after ~2 seconds instead of waiting for new activity. The correct behavior (matching iidy-js) is to ignore events that predate the watch start time and only exit on NEW terminal events.

**Reproduction**:
```
./iidy-hs watch-stack --inactivity-timeout 20 iidy-demo-hello-world
# Stack is already CREATE_COMPLETE
# Exits immediately instead of waiting 20s for inactivity
```

The same bug applies to any command that watches stack events: `watch-stack`, `update-stack`, `delete-stack`, `create-or-update`.

## Root Cause

In `pollForCompletionWith` (`StackOperations.hs:320-341`), terminal status is checked on the latest stack event regardless of when that event occurred. If the stack is already terminal when watching starts, the first poll finds a terminal status and exits.

**iidy-js correct behavior** (`watchStack.ts:58-95`):
```javascript
if (ev.Timestamp > startTime) {  // <-- only NEW events trigger exit
    if (_.includes(terminalStackStates, ev.ResourceStatus)) {
        DONE = true;
    }
}
```

The JS version records `startTime` before the first poll and only considers events with `Timestamp > startTime` for terminal-status exit.

## Work Items

### A: Record watch start time and filter terminal checks

In `pollForCompletionWith`, only treat an event as terminal if its timestamp is AFTER the polling start time. Events that predate the watch should be displayed but never trigger exit.

1. Capture `startTime <- getCurrentTime` before entering the poll loop
2. When checking for terminal status (line ~320), add: event timestamp > startTime
3. The inactivity timeout should still work normally — it just counts from the last NEW event

### B: Audit ALL commands that watch stack events

The event-watching loop is used by multiple commands. Each one must be checked for this bug:
- `watch-stack` — most directly affected (user-reported)
- `create-or-update` — waits for completion after creating changeset
- `update-stack` — waits for completion
- `delete-stack` — waits for completion
- `exec-changeset` — if it watches events after execution

For each command:
1. Trace the code path from the command handler to the poll loop
2. Verify the start time is captured BEFORE the AWS operation (not after)
3. Verify pre-existing terminal events cannot trigger early exit
4. If the operation completes very fast (before first poll), the timestamp filter must still work
5. Check edge case: stack transitions during the gap between operation start and first poll

Don't just fix `watch-stack` and assume the others are fine — explicitly verify each one.

### C: Add test coverage

- Test: stack already terminal at watch start -> doesn't exit immediately
- Test: stack transitions to terminal DURING watch -> exits normally
- Test: inactivity timeout still triggers when no new events arrive
- Test: events before start time are displayed but don't trigger exit

## Codebase Reference

| What                     | Where                                                        |
|--------------------------|--------------------------------------------------------------|
| Poll loop                | `src/Iidy/Cfn/StackOperations.hs:277-346`                   |
| Terminal status check    | `src/Iidy/Cfn/StackOperations.hs:320-341`                   |
| Terminal status list     | `src/Iidy/Cfn/Context.hs:140-150`                           |
| watch-stack command      | `src/Iidy/Cfn/Operations/WatchStack.hs:40-92`               |
| Poll config              | `src/Iidy/Cfn/Operations/WatchStack.hs:68-79`               |
| JS reference (correct)   | `~/src/iidy-js/src/cfn/watchStack.ts:58-95`                 |
| Rust reference           | `~/src/iidy/src/cfn/stack_operations.rs:292-318`            |

## Principles / Constraints

- Match iidy-js behavior: only events after start time trigger terminal exit
- Pre-existing events should still be DISPLAYED (for context), just not trigger exit
- The inactivity timeout is orthogonal — it counts from last new event, not from terminal status
- All commands that watch events (not just watch-stack) must share this fix

## Delegation

- **Can delegate to sub-agent?** Yes (worktree)
- **Model**: Sonnet (straightforward once approach is clear)
- **Notes**: The fix is small (timestamp comparison), but testing needs care with mock event streams
