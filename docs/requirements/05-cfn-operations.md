# PRD: CloudFormation Operations

## Overview

This document specifies the requirements for the 14 CloudFormation stack operations
implemented in iidy-hs. These operations form the core of the iidy workflow: creating,
updating, deleting, describing, and monitoring CloudFormation stacks. All operations are
byte-for-byte behaviorally equivalent to the Rust iidy reference implementation.

Operations are implemented as functions over a CFN context and a uniform output emitter.
This design isolates AWS I/O from output formatting and makes each operation independently
testable. The output dispatch layer routes emitted output event types to the active
renderer (interactive or JSON) based on the user's CLI flags.

## Technical Context

All output events (`Od*` types such as `OdStackDefinition`, `OdNewStackEvents`,
`OdFinalCommandSummary`) are defined in `06-output-system.md`. This document
specifies which events each operation emits and in what order.

All write operations accept a `--client-request-token` for idempotency. All operations
that display progress use a shared spinner infrastructure (braille frames, 100ms ticks,
timing text every 1 second). The output emitter is uniform across all operations.

---

## User Stories

### US-05-001: Create a new stack

**As a** Developer or CI Pipeline, **I want to** deploy a new CloudFormation stack from
an argsfile and template, **so that** infrastructure is provisioned reliably with full
event visibility and a clear success/failure exit code.

**Acceptance Criteria:**

- Loading the argsfile and preprocessing the template succeeds before any AWS API call
  is made.
- Optional lint (ValidateTemplate) runs before CreateStack when requested.
- Templates exceeding 51200 bytes are uploaded to S3 automatically; a template URL is
  used in the request rather than inline body.
- `CreateStack` is called exactly once per invocation.
- `OdStackDefinition` is emitted immediately after the stack is created, before polling
  begins (fetched via `DescribeStacks`).
- `OdPollingStarted "Loading live events..."` is emitted before the polling loop starts.
- During polling, each batch of new events is emitted as `OdNewStackEvents` with
  per-event duration (seconds since operation start, minimum 1 second).
- `OdOperationComplete` is emitted when a terminal status is reached.
- On `DELETE_COMPLETE` (rollback caused stack deletion): return exit code 1 immediately
  without emitting `OdStackContents`.
- On any other terminal status: emit `OdStackContents` (resources, outputs, pending
  changesets), then return exit code 0 if final status is `CREATE_COMPLETE`, else 1.
- All AWS errors other than expected stack-not-found are propagated to the caller.

**Logic Flow:**

```
build create-stack request (primary token)
  → call CreateStack API
  → fetch stack definition → emit OdStackDefinition
  → emit OdPollingStarted
  → poll until terminal status (2s interval)
      on new events:         emit OdNewStackEvents
      on terminal status:    emit OdOperationComplete
  → if DELETE_COMPLETE: return exit code 1
  → collect stack contents → emit OdStackContents
  → if CREATE_COMPLETE: exit 0 else exit 1
```

**Edge Cases:**

- Stack ID is extracted from the CreateStack response; if absent, falls back to
  the stack name for polling.
- Stack definition fetch may return nothing immediately after create (race condition);
  `OdStackDefinition` emission is guarded and silently skipped if the stack is not
  yet queryable.
- The primary client request token is used (not a derived token) to allow safe retries
  of the create call.

**Error Scenarios:**

- Template load failure: error returned before any AWS call.
- CloudFormation API error: propagated to the caller or top-level handler.
- `ROLLBACK_COMPLETE` terminal status: exit code 1 (create failed, stack remains).
- `DELETE_COMPLETE`: exit code 1 (create failed, stack cleaned up).

**Complexity Notes:**

The primary token is used directly for idempotent retries on network failure.
S3 upload logic is centralized in the request builder, not in the operation itself.

---

### US-05-002: Update a stack (direct path)

**As a** Developer or CI Pipeline, **I want to** apply a new template and/or parameter
changes directly to an existing stack, **so that** infrastructure changes are deployed
without a changeset review step.

**Acceptance Criteria:**

- `UpdateStack` is called with the primary client request token.
- The CloudFormation `ValidationError` "No updates are to be performed" is detected and
  handled specially: emit `OdStackDefinition` (current stack state), then re-throw the
  error so the top-level AWS error handler displays it; exit code 1.
- All other AWS errors are returned as `Left`.
- On success: emit `OdStackDefinition`, emit `OdPollingStarted`, poll with
  `OdNewStackEvents` and `OdOperationComplete` callbacks, emit `OdStackContents`, return
  exit code 0 if `UPDATE_COMPLETE`, else 1.
- Stack ID is preferred from the `UpdateStackResponse`; falls back to `getStackId`
  (DescribeStacks) if absent.

**Logic Flow:**

```
build update-stack request (primary token)
  → call UpdateStack API
  → "No updates" error:
      fetch stack definition → emit OdStackDefinition
      re-throw error → top-level handler displays it; exit 1
  → other error: propagate
  → success:
      fetch stack definition → emit OdStackDefinition
      emit OdPollingStarted
      poll until terminal status (2s interval)
          on new events:         emit OdNewStackEvents
          on terminal status:    emit OdOperationComplete
      collect stack contents → emit OdStackContents
      if UPDATE_COMPLETE: exit 0 else exit 1
```

**Edge Cases:**

- The "No updates" path emits `OdStackDefinition` so the user sees the current stack
  state even when there is nothing to deploy — matching Rust behavior.
- The "no updates" check looks for the substring `"No updates are to be performed"`
  in the CloudFormation service error message.

**Error Scenarios:**

- "No updates are to be performed": exit code 1, ValidationError displayed by top-level
  handler.
- Any terminal status other than `UPDATE_COMPLETE`: exit code 1.
- `UPDATE_ROLLBACK_COMPLETE`: update failed and rolled back; exit code 1.

**Complexity Notes:**

Error catching is applied only to the UpdateStack API call, not to the polling phase.
This keeps the "no updates" check focused without swallowing other errors.

---

### US-05-003: Update a stack via changeset

**As a** Platform Engineer or Reviewer, **I want to** preview changes to a stack before
applying them, **so that** destructive or unexpected changes are caught before execution.

**Acceptance Criteria:**

- Emit `OdStackDefinition` before creating the changeset (current stack state).
- Generate a deterministic changeset name: `"iidy-update-" <> take 8 primaryToken`.
- Create an `UPDATE` type changeset via `createChangeset` (polls until
  `CREATE_COMPLETE` or `FAILED`).
- Emit `OdChangeSetResult` (includes console URL, pending changesets, next-steps text).
- If changeset status is `FAILED`: return `Left statusReason`; do not prompt.
- If changeset is valid: prompt for confirmation unless `--yes` flag is set.
  - Confirmation prompt: blank line + `"? " + ANSI bold-bright-red + message + reset + " (y/N) "`.
  - Non-TTY: `"? " <> message <> " (y/N) "` (no ANSI).
  - User declines: return exit code 130.
- On confirmation: execute changeset (see exec-changeset flow); return exit code from
  execution.

**Logic Flow:**

```
fetch stack definition → emit OdStackDefinition
csName = "iidy-update-" + first 8 chars of primary token
create changeset (UPDATE type, csName)
  → emit OdChangeSetResult
  → if changeset FAILED: return error with status reason
  → prompt for confirmation (unless --yes)
      → if declined: exit 130
  → execute changeset
```

**Edge Cases:**

- The changeset name is deterministic from the primary token prefix, so retrying the
  same invocation will attempt to reuse the same changeset name. CloudFormation returns
  an error if the name already exists; the caller must handle or the prior changeset
  must be deleted.
- `OdChangeSetResult` is always emitted (even for `FAILED` changesets) so the user can
  see the failure reason and console URL.

**Error Scenarios:**

- Changeset `FAILED`: error with status reason, no execution.
- User declines: exit code 130.
- Execution fails: exit code from the changeset execution step.

**Complexity Notes:**

The changeset name prefix for update-stack uses `"iidy-update-"`. Create-or-update uses
`"iidy-create-or-update-"`. These are distinct to avoid naming conflicts when both
paths are used on the same token.

---

### US-05-004: Delete a stack with confirmation

**As a** Developer or Platform Engineer, **I want to** safely delete a CloudFormation
stack with a clear confirmation step, **so that** accidental deletions are prevented in
interactive use while CI pipelines can skip the prompt with `--yes`.

**Acceptance Criteria:**

- If stack does not exist: call `getCallerIdentity` (STS), emit `OdStackAbsentInfo`
  (stack name, environment, region, account ID, auth ARN), return exit code 0.
- If stack exists:
  - Emit `OdStackDefinition` (current state).
  - Emit `OdStackEvents` (previous 10 events, title `"Previous Stack Events (max 10):"`,
    with durations calculated from IN_PROGRESS/COMPLETE pairs).
  - Emit `OdStackContents` (current resources, outputs, pending changesets).
  - Unless `--yes` flag: prompt `"Are you sure you want to DELETE the stack <name>?"`.
    - Confirmation prompt uses bold bright red ANSI on TTY, plain text otherwise.
    - User declines: return exit code 130.
  - Obtain stack ARN via `getStackId` for reliable post-delete polling (stack name
    becomes invalid after deletion).
  - Send `DeleteStack` request.
  - Emit `OdPollingStarted "Loading live events..."`.
  - Poll until terminal status with `OdNewStackEvents` and `OdOperationComplete`
    callbacks.
  - Return exit code 0 if `DELETE_COMPLETE`, else 1.

**Logic Flow:**

```
fetch stack
  → absent:
      call STS GetCallerIdentity → emit OdStackAbsentInfo → exit 0
  → exists:
      emit OdStackDefinition
      fetch stack events → emit OdStackEvents (max 10, with durations)
      collect stack contents → emit OdStackContents
      prompt for confirmation (unless --yes)
          → declined: exit 130
      fetch stack ARN → use as poll target
      call DeleteStack API
      emit OdPollingStarted
      poll until terminal status (2s interval)
          on new events:         emit OdNewStackEvents
          on terminal status:    emit OdOperationComplete
      if DELETE_COMPLETE: exit 0 else exit 1
```

**Edge Cases:**

- Polling uses the stack ARN (not name) as target because after `DeleteStack` the stack
  name is no longer queryable; the ARN remains valid.
- All three output sections (definition, events, contents) are emitted before the
  confirmation prompt so the user has full context before deciding.
- If the stack ARN cannot be fetched, polling falls back to the stack name (best effort).

**Error Scenarios:**

- Stack absent: treated as success (idempotent delete), exit code 0.
- User declines: exit code 130 (POSIX "cancelled by signal").
- `DELETE_FAILED`: exit code 1, operator must investigate locked resources.
- AWS API error during delete: propagated as exception to top-level handler.

**Complexity Notes:**

The confirmation prompt performs TTY detection on stdout and uses line buffering on stdin
for reliable line reads. The ANSI escape sequence for bold bright red is `\ESC[1;91m`,
reset is `\ESC[0m`.

---

### US-05-005: Smart create-or-update routing

**As a** Developer or CI Pipeline, **I want to** run a single command that creates or
updates a stack depending on whether it already exists, **so that** the same command
works for both initial deployments and subsequent updates without branching in scripts.

**Acceptance Criteria:**

- Check stack existence before taking any action (via `stackExists`, which treats
  `DELETE_COMPLETE` as absent).
- Route to one of four paths based on `(exists, useChangeset)`:

  | exists | useChangeset | Path                                          |
  | ------ | ------------ | --------------------------------------------- |
  | True   | False        | Direct update (updateStack)                   |
  | True   | True         | UPDATE changeset (updateWithChangeset)        |
  | False  | False        | Direct create (createStack)                   |
  | False  | True         | CREATE changeset with random name             |

- `ROLLBACK_COMPLETE` status is treated as absent (stack exists but is broken; treat as
  absent for create-or-update purposes). The existence check returns `False` for
  `DELETE_COMPLETE` stacks, and the broader "stack absent" definition handles
  `ROLLBACK_COMPLETE`.
- The `--yes` flag is threaded through to all confirmation-requiring paths.
- Output emission sequences match those of the dispatched operation exactly.

**Logic Flow (changeset create path for new stack):**

```
generate random adjective-noun changeset name (e.g. "swift-tiger")
create changeset (CREATE type, csName)
  → fetch stack definition → emit OdStackDefinition (stack in REVIEW_IN_PROGRESS)
  → build changeset creation result → emit OdChangeSetResult
  → if FAILED: return error with status reason
  → prompt for confirmation (unless --yes)
      → declined: exit 130
  → execute changeset
```

**Logic Flow (changeset update path for existing stack):**

```
fetch stack definition → emit OdStackDefinition
csName = "iidy-create-or-update-" + first 8 chars of primary token
create changeset (UPDATE type, csName)
  → emit OdChangeSetResult
  → if FAILED: return error with status reason
  → prompt for confirmation (unless --yes)
      → declined: exit 130
  → execute changeset
```

**Edge Cases:**

- Random changeset names for the CREATE path use an adjective-noun vocabulary:
  `["red","blue","green","happy","clever","brave","swift","mighty"]` x
  `["cat","dog","bird","fish","lion","eagle","shark","tiger"]`. These are used only when
  the user has not provided a changeset name.
- For the CREATE changeset path: after the changeset is created, the stack exists in
  `REVIEW_IN_PROGRESS`; the stack definition is fetched and emitted at this point.

**Error Scenarios:**

- Stack existence check failure: AWS error propagated as exception.
- Any error path: displayed by top-level handler.
- User declines any confirmation: exit code 130.

**Complexity Notes:**

The stack existence check returns `False` for `DELETE_COMPLETE` stacks. However, the
stack definition fetch still succeeds for such stacks (they are queryable). The
distinction matters: existence is used for routing; the definition fetch is used for
display.

---

### US-05-006: Create and execute changesets independently

**As a** Reviewer or Platform Engineer, **I want to** create a changeset without
immediately executing it, and separately execute a named changeset, **so that** change
review and deployment can be performed as separate steps with different approvers.

**Acceptance Criteria (create-changeset):**

- Accept a changeset name from the user or generate a deterministic/random name.
- Determine changeset type (`CREATE` or `UPDATE`) based on stack existence.
- Call `CreateChangeSet` API.
- Poll `DescribeChangeSet` every 2 seconds until status is `CREATE_COMPLETE`, `FAILED`,
  `DELETE_COMPLETE`, or `DELETE_FAILED`.
- Emit `OdChangeSetResult` with:
  - Changeset name, stack name, type (`CREATE` or `UPDATE`).
  - Console URL (percent-encoded ARNs):
    `https://<region>.console.aws.amazon.com/cloudformation/home?region=<region>#/changeset/detail?stackId=<encoded>&changeSetId=<encoded>`.
  - `hasChanges` flag (based on whether `csiChanges` is non-empty).
  - Next-steps text: `iidy --region <region> exec-changeset --stack-name <name> <argsfile> <csname>`.
- Return the `ChangeSetInfo` to the caller (for further action in other paths).

**Acceptance Criteria (exec-changeset):**

- Derive an `execute-changeset` token from the primary token via SHA256.
- Call `ExecuteChangeSet` API.
- Emit `OdStackDefinition` (current stack state after execution start).
- Emit `OdStackEvents` with title `"Previous Stack Events (max 10):"` (pre-existing
  events, max 10, with durations from IN_PROGRESS/COMPLETE pairs).
- Emit `OdPollingStarted "Loading live events..."`.
- Poll until terminal status with `OdNewStackEvents` and `OdOperationComplete` callbacks.
- On `DELETE_COMPLETE`: return exit code 1 without emitting `OdStackContents`.
- On any other terminal status: emit `OdStackContents`.
- Return exit code 0 if final status is in `createSuccessStates ++ updateSuccessStates`
  (`CREATE_COMPLETE` or `UPDATE_COMPLETE`), else 1.

**Logic Flow (exec-changeset):**

```
derive "execute-changeset" token from primary token
  → call ExecuteChangeSet API
  → fetch stack ARN (fallback to stack name)
  → fetch stack definition → emit OdStackDefinition
  → fetch stack events → emit OdStackEvents (max 10, title "Previous Stack Events (max 10):")
  → emit OdPollingStarted
  → poll until terminal status (2s interval)
      on new events:         emit OdNewStackEvents
      on terminal status:    emit OdOperationComplete
  → if not DELETE_COMPLETE: collect stack contents → emit OdStackContents
  → if CREATE_COMPLETE or UPDATE_COMPLETE: exit 0 else exit 1
```

**Edge Cases:**

- Region for the console URL is extracted from the stack ARN
  (`arn:aws:cloudformation:REGION:...`).
- ARN characters are percent-encoded in changeset console URLs (`:` → `%3A`, `/` →
  `%2F`); stack info URLs do not encode the ARN.
- Transient errors during changeset polling are ignored; polling continues.

**Error Scenarios:**

- Changeset `FAILED` after creation: error with status reason.
- `ExecuteChangeSet` API error: propagated as exception.
- `DELETE_COMPLETE` after execution: exit code 1.

**Complexity Notes:**

The changeset creation result includes a `nextSteps` field with ready-to-paste CLI
commands and a `pendingChangesets` field holding the full changeset info list for the
JSON renderer.

---

### US-05-007: Describe stack state

**As a** Developer or Platform Engineer, **I want to** inspect the current state of a
stack including its definition, recent events, resources, and outputs, **so that** I can
understand what was deployed, the current health, and what resources exist.

**Acceptance Criteria:**

- Accept a `--num-events` parameter (default N) controlling how many events are shown.
- If stack does not exist: call `getCallerIdentity` (STS), emit `OdStackAbsentInfo`
  (stack name, environment, region, account, auth ARN), return `Right ()`.
- If stack exists: emit `OdStackDefinition`, `OdStackEvents`, `OdStackContents` in that
  order.
- `OdStackEvents` title format: `"Previous Stack Events (max <N>):"`.
- Event durations use the historical pairing algorithm (`calculateEventDurations`):
  matches `_IN_PROGRESS` to subsequent `_COMPLETE` or `_FAILED` for the same
  `logicalResourceId/resourceType` key; duration is max(1, floor(end - start)) seconds.
- `OdStackContents` includes resources (from `DescribeStackResources`), outputs (from
  `DescribeStacks`), pending changesets (from `ListChangeSets`). Exports field is empty
  (requires a separate `ListExports` call not currently implemented).
- `StackDefinition.sdConsoleUrl` format:
  `https://<region>.console.aws.amazon.com/cloudformation/home?region=<region>#/stacks/stackinfo?stackId=<ARN>`.
  The ARN is not percent-encoded in this URL.

**Logic Flow:**

```
fetch stack
  → absent:
      call STS GetCallerIdentity → emit OdStackAbsentInfo → return
  → exists:
      fetch stack events
      collect stack contents
      convert stack to stack definition
      build events display (with event duration calculation)
      emit OdStackDefinition
      emit OdStackEvents
      emit OdStackContents
```

**Edge Cases:**

- Events are returned most-recent-first from AWS; the display builder takes the first
  `numEvents` and then passes them to the event duration calculator which sorts
  chronologically to find pairs before returning results in original (most-recent-first)
  order.
- `StackDefinition.sdStacksetName` is populated from the `"StackSetName"` tag if
  present.

**Error Scenarios:**

- Stack absent: treated as a non-error (emits `OdStackAbsentInfo`, exits 0); the STS
  call provides auth context to help diagnose wrong region/account issues.
- AWS API error in contents collection: propagated as exception.

**Complexity Notes:**

`describe-stack` and `delete-stack` (pre-delete display) share the same
event-display-building and event-duration-calculation logic for historical events.
Live polling events use a separate duration calculation against the operation start
time instead.

---

### US-05-008: Watch stack events in real-time

**As a** Developer or CI Pipeline, **I want to** observe the event stream of an
in-progress stack operation and follow it until completion, **so that** I can monitor
deployments initiated by other tools (console, other scripts) without polling manually.

**Acceptance Criteria:**

- If stack does not exist: return `Left "Stack not found: <name>"` (non-zero exit).
- If stack exists:
  - Emit `OdStackDefinition`.
  - Obtain stable stack ARN via `getStackId`.
  - Fetch initial events; emit `OdStackEvents` (previous 10, with historical durations).
  - Emit `OdPollingStarted "Loading live events..."`.
  - Poll with `pcWaitForStatusChange = True`: do not exit on a terminal status until at
    least one new event has been observed. This prevents exiting immediately if the
    stack is already in a terminal state from a previous operation.
  - Filter duplicate events using the initial event ID set (`seenIds`).
  - Emit `OdNewStackEvents` for each batch of genuinely new events.
  - Emit `OdOperationComplete` when a terminal status is reached.
  - If inactivity timeout is configured and triggers (after events have been seen):
    emit `OdInactivityTimeout`.
  - If final status is `DELETE_COMPLETE`: return `Right 0` without emitting
    `OdStackContents`.
  - Otherwise: emit `OdStackContents`, return `Right 0`.
  - Once polling begins, always exit 0 (watch merely observes; it does not judge
    success/failure of the underlying operation). Stack-not-found exits non-zero.

**Logic Flow:**

```
fetch stack
  → absent: return error "Stack not found: <name>"
  → exists:
      emit OdStackDefinition
      fetch stack ARN
      fetch initial events → emit OdStackEvents (10 events with durations)
      record initial event ID set (for deduplication)
      emit OdPollingStarted
      poll with "wait for status change" enabled, optional inactivity timeout
          on new events: filter out seen IDs → emit OdNewStackEvents
          on terminal status: emit OdOperationComplete
          on inactivity timeout: emit OdInactivityTimeout
      if DELETE_COMPLETE: exit 0
      else: collect stack contents → emit OdStackContents → exit 0
```

**Edge Cases:**

- The "wait for status change" option ensures watch-stack does not exit instantly on a
  stack that is already in a terminal state from a prior operation. Polling only
  terminates after at least one new event has been emitted.
- The inactivity timeout only fires after new events have been seen.
- Event deduplication compares event IDs from the initial snapshot against IDs in each
  poll response; events matching any seen ID are silently dropped.

**Error Scenarios:**

- Stack not found: error, non-zero exit (unlike other absent-stack operations which
  return exit 0).
- Inactivity timeout fires: `OdInactivityTimeout` emitted, then exit 0.
- Overall timeout fires: exit 0 with empty final status.

**Complexity Notes:**

watch-stack is the only operation that uses the "wait for status change" polling option.
This changes the terminal-status check from "check immediately" to "check only after at
least one new event has been observed".

---

### US-05-009: Detect stack drift

**As a** Platform Engineer, **I want to** detect whether the actual state of stack
resources has drifted from their CloudFormation-managed configuration, **so that**
out-of-band changes are identified before they cause deployment failures.

**Acceptance Criteria:**

- If stack does not exist: return `Left "Stack not found: <name>"`.
- Emit `OdStackDefinition` for the existing stack.
- Check drift cache: skip a new `DetectStackDrift` call if the stack's
  `driftInformation.lastCheckTimestamp` is within `driftCacheSecs` seconds (default
  300) and the drift status is not `NOT_CHECKED`.
- If drift detection is needed:
  - Emit `OdStatusUpdate` with message `"Checking for stack drift..."`, level `LevelInfo`.
  - Call `DetectStackDrift`, obtain `stackDriftDetectionId`.
  - Poll `DescribeStackDriftDetectionStatus` every 3 seconds until status is not
    `DETECTION_IN_PROGRESS`.
- Collect drift results via paginated `DescribeStackResourceDrifts`.
- Filter out `IN_SYNC` resources; only drifted resources are included.
- Emit `OdStackDrift` with the list of `DriftedResource` records (logical ID, physical
  ID, resource type, drift status, property differences).
- Return `Right ()`.

**Logic Flow:**

```
fetch stack
  → absent: return error "Stack not found: <name>"
  → exists:
      emit OdStackDefinition
      check drift cache
        → if cache miss or NOT_CHECKED:
            emit OdStatusUpdate "Checking for stack drift..."
            call DetectStackDrift → detection ID
            poll DescribeStackDriftDetectionStatus every 3s until complete
      collect drift data (paginated DescribeStackResourceDrifts)
        → filter out IN_SYNC resources
      emit OdStackDrift
```

**Edge Cases:**

- Cache check: if `driftInformation` is absent or `NOT_CHECKED`, always initiate
  detection.
- If `lastCheckTimestamp` is present and within cache window, skip detection and use the
  existing drift status.
- `IN_SYNC` resources are filtered out before emitting `OdStackDrift`; the output
  contains only drifted resources.
- Drift results are paginated; all pages are fetched before filtering.

**Error Scenarios:**

- Stack not found: error returned.
- Drift detection API error: propagated as exception.
- All resources are `IN_SYNC`: `OdStackDrift` emitted with empty drifted resources list.

**Complexity Notes:**

Drift detection uses its own simple polling loop (3-second interval), separate from the
main stack event polling infrastructure. It has no event callbacks — just wait for the
detection status to leave `DETECTION_IN_PROGRESS`.

---

### US-05-010: Poll for operation completion

**As a** Developer, **I want to** have all long-running CloudFormation operations
automatically wait for completion with live event feedback and a spinner, **so that** I
do not need to poll manually or write wrapper scripts.

**Acceptance Criteria:**

- All write operations (create-stack, update-stack, delete-stack, exec-changeset)
  poll with a 2-second interval.
- The poll function accepts an injectable event-fetching function enabling unit testing
  without AWS.
- Poll configuration fields:
  - `intervalSeconds`: 2 (default).
  - `timeoutSeconds`: optional overall timeout; empty string status returned on expiry.
  - `inactivityTimeoutSecs`: optional inactivity timeout; only triggers after at least
    one new event has been seen (unless `waitForStatusChange` is False).
  - `waitForStatusChange`: False for all operations except watch-stack.
  - `onNewEvents`: callback receiving new events in chronological order.
  - `onOperationComplete`: callback receiving elapsed seconds, start time, and a
    `skipRemainingSections` flag.
  - `onInactivityTimeout`: callback receiving inactivity timeout info.
  - `onPollTick`: called each poll cycle (used by the spinner).
- `OdPollingStarted` is emitted before polling begins in every write operation.
- `OdOperationComplete.ociSkipRemainingSections` is True when the terminal status is
  `DELETE_COMPLETE` and the terminal status list includes `DELETE_COMPLETE`; renderers
  use this flag to suppress further output sections.
- Terminal status detection: the most recent stack-level event
  (`logicalResourceId == stackName` or `resourceType == "AWS::CloudFormation::Stack"`)
  is used to determine current status.
- The spinner displays braille frames (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) at 100ms intervals, with
  timing text updated every 1 second showing total elapsed and time since last event.

**Logic Flow (inner poll loop):**

```
record start time
record last-event time = start time
record has-seen-new-events = False
loop:
  wait intervalSeconds
  call onPollTick
  fetch events
  newEvents = events not in lastEventIds
  if newEvents non-empty:
    update last-event time
    set has-seen-new-events = True
    call onNewEvents (chronological order)
  check inactivity timeout:
    if configured && no new events && elapsed > timeout
       && (not waitForStatusChange || has-seen-new-events):
      call onInactivityTimeout
      return ""
  check overall timeout → return ""
  check terminal status:
    if should-check-terminal && current status in terminal statuses:
      call onOperationComplete
      return current status
  recurse with lastEventIds = all event IDs from this poll
```

**Edge Cases:**

- New events are delivered to the callback in chronological order (reversed from AWS
  response which is most-recent-first).
- `lastEventIds` is updated each iteration from the full events list, not just new
  events, to handle gaps.
- Duration calculation for live events: `max(1, floor(eventTime - operationStartTime))` seconds.

**Error Scenarios:**

- AWS errors during polling: propagated as exceptions (not caught within the loop).
- Overall timeout: return empty string `""` as final status; operations treating empty
  string as non-success return exit code 1.
- Inactivity timeout: return empty string `""`, `OdInactivityTimeout` emitted first.

**Complexity Notes:**

The poll function accepts an injectable event-fetching action, enabling pure unit tests
via mock event sequences. This is the dependency-injection seam for the polling system.

---

### US-05-011: Handle operation errors and edge cases

**As a** Developer or CI Pipeline, **I want to** receive clear, actionable error
messages for all expected failure modes, **so that** I can diagnose and fix issues
without reading AWS documentation.

**Acceptance Criteria:**

- "No updates are to be performed" `ValidationError` from `UpdateStack`:
  - Emit `OdStackDefinition` (current stack state for context).
  - Re-throw the error so the top-level AWS error handler formats and displays it.
  - Exit code 1.
- Stack absent in delete-stack: emit `OdStackAbsentInfo` with STS caller identity
  (account ID, ARN); exit code 0 (idempotent).
- Stack absent in describe-stack: emit `OdStackAbsentInfo` with STS caller identity;
  return `Right ()`.
- Stack absent in watch-stack: return `Left "Stack not found: <name>"` (non-zero exit).
- Changeset `FAILED` status: return `Left statusReason`; do not proceed to execution.
- `FAILED` changeset check uses `csiStatus info == "FAILED"` (exact string equality on
  the converted `ChangeSetStatus`).
- All unrecognized AWS errors: propagated as exceptions to the top-level handler.
- Tag values in `StackArgs` must be `Text` (strings); non-string YAML values in argsfiles
  (e.g., bare integers) are rejected with a descriptive error before any API call.
- Terminal status list for each operation:
  - create-stack: `CREATE_COMPLETE`, `ROLLBACK_COMPLETE`, `DELETE_COMPLETE`,
    `UPDATE_COMPLETE`, `UPDATE_ROLLBACK_COMPLETE`, `IMPORT_COMPLETE`,
    `IMPORT_ROLLBACK_COMPLETE`, `CREATE_FAILED`, `DELETE_FAILED`, `ROLLBACK_FAILED`,
    `UPDATE_ROLLBACK_FAILED`, `IMPORT_ROLLBACK_FAILED`, `DELETE_SKIPPED`,
    `REVIEW_IN_PROGRESS`.
  - update-stack: same as create-stack.
  - delete-stack: `DELETE_COMPLETE`, `DELETE_FAILED`, `CREATE_FAILED`,
    `ROLLBACK_COMPLETE`, `ROLLBACK_FAILED`, `UPDATE_ROLLBACK_FAILED`.
  - exec-changeset / watch-stack: `CREATE_COMPLETE`, `CREATE_FAILED`, `DELETE_COMPLETE`,
    `DELETE_FAILED`, `ROLLBACK_COMPLETE`, `ROLLBACK_FAILED`, `UPDATE_COMPLETE`,
    `UPDATE_FAILED`, `UPDATE_ROLLBACK_COMPLETE`, `UPDATE_ROLLBACK_FAILED`,
    `IMPORT_COMPLETE`, `IMPORT_ROLLBACK_COMPLETE`, `IMPORT_ROLLBACK_FAILED`.

**Logic Flow ("no updates" check):**

```
check service error message for substring "No updates are to be performed"
  → if found: treat as no-updates error
  → if not found: treat as generic error
```

**Edge Cases:**

- Stack definition fetch catches AWS `ValidationError` messages containing `"does not
  exist"` and returns absent; other errors are re-thrown.
- The stack existence check returns `False` for `DELETE_COMPLETE` stacks (not just absent
  stacks).
- Event duration minimum is 1 second: `max(1, floor(end - start))`.

**Error Scenarios:**

- Lint: template > 51200 bytes emits a warning and skips validation; no error exit.
- Estimate-cost: template load failure returns an error.
- Describe-stack-drift: stack not found returns an error; drift detection errors
  propagated as exceptions.

**Complexity Notes:**

The `OdStackAbsentInfo` output event type carries full STS identity (account, auth ARN)
so the renderer can show whether the user is authenticated to the expected account and
region. This directly addresses a common failure mode: running commands against the wrong
account.

---

### US-05-012: Idempotent operations via tokens

**As a** CI Pipeline, **I want to** safely retry failed CloudFormation operations using
client request tokens, **so that** network failures or timeouts do not result in
duplicate resources.

**Acceptance Criteria:**

- All write operations accept an optional `--client-request-token` CLI flag.
- If not provided, a UUID is generated at startup and used as the primary token.
- The primary token is used directly for single-step operations (CreateStack, UpdateStack).
- Multi-step operations derive per-step tokens deterministically:
  - A step token is produced by hashing `(primaryToken + stepName)` with SHA256 (no
    separator), then formatting as `take(8, primaryToken) + "-" + take(8, hexHash)`.
  - `exec-changeset` derives a token with step name `"execute-changeset"`.
- Derived tokens are tracked for the command metadata summary.
- Changeset names are deterministic from the token prefix:
  - update-stack path: `"iidy-update-"` + first 8 chars of primary token
  - create-or-update update path: `"iidy-create-or-update-"` + first 8 chars of primary token
  - create-or-update create path: random adjective-noun name
- The primary token is a UUID string; the "first 8 chars" refers to the first 8
  characters of that UUID.

**Logic Flow:**

```
primary token = user-provided --client-request-token | generated UUID

step token derivation:
  token = first 36 chars of sha256hex(primaryToken + ":" + stepName)

token tracking:
  derived tokens are appended to the used-tokens list on derivation
```

**Edge Cases:**

- If the same primary token is used for a `CreateStack` retry, CloudFormation
  recognizes the token and returns the existing stack creation result rather than
  creating a duplicate.
- Deterministic changeset names mean retrying `update-stack --changeset` with the same
  token will attempt to reuse the same changeset; if it already exists, CloudFormation
  returns an error. The user must delete the prior changeset or use a different token.
- The create-or-update CREATE path uses a random name rather than a deterministic one,
  because at the point of creation the stack does not yet exist and there is no stable
  name to derive from.

**Error Scenarios:**

- Token too long for CloudFormation (max 128 characters): request builder truncates to
  the API limit.
- Duplicate changeset name: CloudFormation API error propagated to caller.

**Complexity Notes:**

All used tokens (primary and derived) are tracked and included in the `OdCommandMetadata`
output event so the operator can reference them for CloudFormation console lookups and
retries. Tokens are returned in forward-chronological order.

---

## Testing Requirements

- All polling logic is tested with mock event sequences (no AWS calls required). Test
  scenarios include: immediate terminal status, status change after N iterations,
  inactivity timeout, and "wait for status change" behavior.
- The "no updates" error detection is unit-tested with exact error message strings.
- Confirmation input parsing is unit-tested covering `"y"`, `"yes"`, `"Y"`, `"YES"`,
  `""`, `"no"`, `"n"`, and arbitrary strings.
- Event duration calculation is unit-tested with chronological and reverse-chronological
  event sequences, paired and unpaired events, and minimum-duration enforcement.
- Live event duration calculation is unit-tested with known timestamps to verify
  `max(1, ...)` clamping and floor behavior.
- Event display building is unit-tested for truncation info and title format.
- Stack state checking and random changeset name generation are unit-tested.
- Changeset creation result is unit-tested for console URL format (percent-encoding of
  ARNs), next-steps text format, and changeset type values.
- Stack console URL building is unit-tested for stack info URL format (no
  percent-encoding).
- Region extraction from ARN is unit-tested with standard and malformed ARNs.
- Integration tests verify the complete `OdStackDefinition → OdStackEvents →
  OdStackContents` emission sequence for describe-stack.
- All AWS calls are mocked via the context dependency; no real AWS credentials are
  required in the test suite.
- 100% of tests must pass before any commit. No test stubs, no skipped assertions.

## Cross-References

- `06-output-system.md` — all `OutputData` event types emitted by operations
- `08-aws-integration.md` — credential chain, region resolution, NTP time provider
- `07-error-handling.md` — error display pipeline that surfaces AWS errors
- `DIVERGENCES.md` — known behavioral differences from Rust
- Rust oracle: `~/src/iidy/src/cfn/` (read-only reference)
