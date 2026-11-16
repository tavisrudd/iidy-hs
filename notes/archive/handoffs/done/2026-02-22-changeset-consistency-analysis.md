# Changeset Consistency Analysis

**Status: DONE** — all changeset paths implemented in Phase 13.5

## Overview

This document analyzes changeset handling across all commands that support changesets,
comparing Rust behavior to Haskell implementation, and identifying gaps for consistent
behavior from similar starting stack states.

## Commands That Support Changesets

| Command | Changeset Flag | Rust Status | Haskell Status |
|---------|---------------|-------------|----------------|
| `create-changeset` | N/A (always creates) | Full | Partial (hardcoded name, no REVIEW_IN_PROGRESS detection) |
| `exec-changeset` | N/A (always executes) | Full | Done (Session 30) |
| `update-stack` | `--changeset` | Full | **NOT IMPLEMENTED** (flag parsed, ignored) |
| `create-or-update` | `--changeset` | Full (5 paths) | **NOT IMPLEMENTED** (flag parsed, ignored) |

## State Matrix: Stack States x Commands x Changeset Flag

### Starting States

1. **Stack does not exist** — No stack with that name
2. **Stack exists (normal)** — Stack in a terminal state (CREATE_COMPLETE, UPDATE_COMPLETE, etc.)
3. **Stack in REVIEW_IN_PROGRESS** — Stack created by a CREATE-type changeset but not yet executed
4. **Stack in UPDATE_REVIEW_IN_PROGRESS** — Stack with pending UPDATE changeset (rare)

### Rust Behavior Matrix

| State | create-changeset | exec-changeset | update-stack --changeset | create-or-update --changeset |
|-------|-----------------|----------------|-------------------------|------------------------------|
| **Does not exist** | Creates CREATE-type CS, shows result | Error (no stack) | Error (no stack to update) | Creates CREATE-type CS → confirm → execute |
| **Exists (normal)** | Creates UPDATE-type CS, shows result | Executes named CS, watches | Creates UPDATE CS → confirm → execute | Creates UPDATE CS → confirm → execute |
| **REVIEW_IN_PROGRESS** | Returns existing CS info (no new creation) | Executes named CS, watches | Returns existing CS info | Returns existing CS info |

### Haskell Behavior Matrix (Current)

| State | create-changeset | exec-changeset | update-stack --changeset | create-or-update --changeset |
|-------|-----------------|----------------|-------------------------|------------------------------|
| **Does not exist** | **WRONG**: Passes `stackExists=True` always! Creates UPDATE CS → API error | Works (error) | **Flag ignored** → direct update → error | **Flag ignored** → direct create (no CS) |
| **Exists (normal)** | Creates UPDATE CS, shows result | Works (Session 30) | **Flag ignored** → direct update | **Flag ignored** → direct update |
| **REVIEW_IN_PROGRESS** | **No detection** → tries to create again → may error | Works | **Flag ignored** → direct update | **Flag ignored** → may error |

## Identified Gaps

### GAP 1: create-changeset always passes `stackExists=True`

**File**: `app/Main.hs:118`
```haskell
result <- createChangeset ctx sa csName True fp env
--                                    ^^^^ hardcoded True
```
**Rust behavior**: Calls `check_stack_state()` to determine if stack exists, then sets changeset type accordingly (CREATE or UPDATE).

**Impact**: Cannot create a new stack via changeset. Always sends ChangeSetType=UPDATE.

**Fix**: Call `stackExists` before `createChangeset` to determine the correct type.

### GAP 2: Changeset name generation

**File**: `app/Main.hs:117`
```haskell
let csName = maybe "changeset" id (ccsChangesetName args)
```
**Rust behavior**:
- `create-changeset` without name → `generate_dashed_name()` (e.g., "brave-cat")
- `update-stack --changeset` → `"iidy-update-" <> token[..8]`
- `create-or-update --changeset` (update) → `"iidy-create-or-update-" <> token[..8]`
- `create-or-update --changeset` (create) → `generate_dashed_name()`

**Impact**: Second `create-changeset` run without explicit name will fail because "changeset" already exists. Random names prevent collisions.

**Fix**: Implement `generateDashedName` (simple adjective-noun pairs).

### GAP 3: update-stack --changeset path completely missing

**File**: `app/Main.hs:98-100` — calls `updateStack` directly, ignores `usaChangeset`

**Rust behavior**: When `--changeset` is set:
1. Fetch StackDefinition (async)
2. Generate name: `"iidy-update-" <> token[..8]`
3. Create UPDATE changeset
4. Show ChangeSetResult
5. Prompt for confirmation (unless `--yes`)
6. Execute changeset → watch stack

**Fix**: Add `updateStackWithChangeset` function. Wire `usaChangeset` and `usaYes` from CLI.

### GAP 4: create-or-update --changeset paths missing (3 of 5 paths)

**File**: `app/Main.hs:102-104`, `CreateOrUpdate.hs:42` — `_useChangeset` ignored

**Rust 5 paths**:
1. Stack exists + no changeset + changes → direct update ✅ (implemented)
2. Stack exists + no changeset + no changes → exit 0 ✅ (implemented via "No updates" catch)
3. Stack exists + changeset → create UPDATE CS → confirm → execute ❌
4. Stack doesn't exist + no changeset → direct create ✅ (implemented)
5. Stack doesn't exist + changeset → create CREATE CS → show definition → confirm → execute ❌

**Fix**: Implement paths 3 and 5 in `CreateOrUpdate.hs`.

### GAP 5: No REVIEW_IN_PROGRESS detection

**Rust**: `check_stack_state()` detects REVIEW_IN_PROGRESS and returns existing changeset info
instead of trying to create a new one.

**Haskell**: No such check. `createChangeset` will attempt to create a new CS on a stack
already in REVIEW_IN_PROGRESS, which may error.

**Fix**: Add `checkStackState` helper that returns `StackState` (DoesNotExist | Exists | ReviewInProgress Text).

### GAP 6: No confirmation flow for changeset execution

**Rust**: `confirm_changeset_execution()` shows "Do you want to execute this changeset now?"
unless `--yes` is provided. Returns exit code 130 on decline.

**Haskell**: No such confirmation exists.

**Fix**: Add `confirmChangesetExecution` using existing confirmation infrastructure (same as delete-stack).

## Implementation Plan

### Phase 1: Shared Helpers (prerequisite for all paths)

1. **`generateDashedName`** — Random adjective-noun name generator
2. **`checkStackState`** — Returns DoesNotExist | Exists | ReviewInProgress
3. **`confirmChangesetExecution`** — Prompt user, handle --yes flag

### Phase 2: Fix create-changeset

1. Call `stackExists` to determine correct changeset type (not hardcoded True)
2. Use `generateDashedName` when no name provided
3. Handle REVIEW_IN_PROGRESS (return existing changeset info)

### Phase 3: Implement update-stack --changeset

1. Add `updateStackWithChangeset` function
2. Wire `usaChangeset` and `usaYes` through Main.hs → updateStack
3. Flow: StackDefinition → create CS → show result → confirm → execute

### Phase 4: Implement create-or-update changeset paths

1. Add changeset path for "stack exists + changeset" (UPDATE type)
2. Add changeset path for "stack doesn't exist + changeset" (CREATE type)
3. Wire through both `usaChangeset` and `usaYes`

### Phase 5: Test Coverage

1. Unit tests for `generateDashedName` (format, non-empty)
2. Unit tests for `checkStackState` (mock responses)
3. Integration test: update-stack --changeset flow (mock)
4. Integration test: create-or-update --changeset flow (mock, both paths)
5. Test: create-changeset name collision avoidance

## Confirmation Flow Design

```
┌─────────────────────────┐
│ update-stack --changeset│
│ create-or-update --cs   │
└────────┬────────────────┘
         │
    Create changeset
         │
    Show ChangeSetResult
    (changes, console URL)
         │
    ┌────┴────┐
    │ --yes?  │
    └────┬────┘
    yes  │  no
    ┌────┘  └────┐
    │            Prompt: "Do you want to execute
    │            this changeset now? [y/N]"
    │            │
    │       ┌────┴────┐
    │       yes       no
    │       │         │
    │       │    exit 130
    │       │
    └───┬───┘
        │
   Execute changeset
   (reuses executeChangeset)
```
