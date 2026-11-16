# PRD: CloudFormation Operations

## Overview

This document specifies the requirements for the CloudFormation stack operations
implemented in iidy. These operations form the core of the iidy workflow: creating,
updating, deleting, describing, and monitoring CloudFormation stacks. All operations are
byte-for-byte behaviorally equivalent to the Rust iidy reference implementation unless
explicitly noted as a divergence.

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

## Template Loading

Before any AWS API call, templates must be loaded and validated. Template loading follows
a strict precedence order:

```pseudocode
loadTemplate(spec, argsfilePath, env, importCfg):
  if spec is None:
    return TemplateResult(body=None, url=None)
  if spec starts with "s3://" or "https://s3":
    return TemplateResult(body=None, url=spec)
  if spec starts with "http://" or "https://":
    return TemplateResult(body=None, url=spec)
  if spec starts with "render:":
    path = resolveRelativeTo(stripPrefix("render:", spec), argsfilePath)
    ast  = parseYaml(readFile(path))
    ast' = injectEnvValues(ast, env)    -- adds $envValues.environment
    result = preprocessYaml(ast', importCfg)
    body = emitYaml(result)
    checkSize(body)                     -- error if > 51199 bytes
    return TemplateResult(body=body, url=None)
  path = resolveRelativeTo(spec, argsfilePath)
  if fileExists(path):
    body = readFileUtf8(path)
    if body contains "$imports:":
      error("Template uses preprocessor syntax; prefix with 'render:'")
    checkSize(body)
    return TemplateResult(body=body, url=None)
  else:
    -- Treat spec as inline content
    if spec contains "$imports:":
      error("Inline template uses preprocessor syntax; prefix with 'render:'")
    return TemplateResult(body=spec, url=None)
```

**Size limits:**

| Boundary       | Limit        | Action on exceed                              |
|----------------|--------------|-----------------------------------------------|
| Inline body    | 51199 bytes  | Error with descriptive message                |
| S3 upload      | 999999 bytes | Error (reserved for future S3 auto-upload)    |

Templates exceeding 51199 bytes cannot be passed inline; the user must upload to S3 and
provide an S3 URL. The `render:` prefix triggers full YAML preprocessing (resolving
`$imports`, `$defs`, handlebars interpolation, custom tags) before passing to CFN.

---

## Request Building

Each write operation builds its API request from a `StackArgs` record and the CFN context.
Common fields across all request types:

| Field                      | Source                                          |
|----------------------------|-------------------------------------------------|
| templateBody / templateURL | Template loading result                         |
| capabilities               | `StackArgs.capabilities` mapped to CFN enums    |
| parameters                 | `StackArgs.parameters` map -> CFN Parameter list|
| tags                       | `StackArgs.tags` map -> CFN Tag list            |
| roleARN                    | `serviceRoleArn` with fallback to `roleArn`     |
| clientRequestToken         | Primary or derived token (see US-05-012)        |
| notificationARNs           | `StackArgs.notificationArns`                    |

**CreateStack** additionally passes: `timeoutInMinutes`, `disableRollback`,
`enableTerminationProtection`, `onFailure`, `stackPolicyBody`, `resourceTypes`.

**UpdateStack** additionally passes: `stackPolicyBody`, `resourceTypes`.

**DeleteStack** uses the primary token directly (not derived).

**CreateChangeSet** additionally passes: `changeSetType` (CREATE or UPDATE),
`resourceTypes`. Uses a derived token with step name `"create-changeset"`.

---

## Confirmation Prompt

All operations requiring user confirmation share a single prompt implementation:

```pseudocode
requestConfirmation(prompt):
  setBuffering(stdin=LineBuffering, stdout=NoBuffering)
  isTty = isTerminalDevice(stdout)
  print("")                           -- blank line before prompt
  if isTty:
    print("? \ESC[1;91m" + prompt + "\ESC[0m (y/N) ")
  else:
    print("? " + prompt + " (y/N) ")
  flush(stdout)
  answer = readLine(stdin)
  return "y" or "yes" (case-insensitive) -> Confirmed
         anything else                   -> Declined
```

On decline, operations return exit code 130 (POSIX "cancelled by signal").

---

## Stack Status Detection

Stack statuses are represented as a sum type covering all AWS CloudFormation statuses.
Terminal status detection uses two conditions (both must match):

```pseudocode
isStackEvent(event, stackId):
  event.logicalResourceId == stackNameFromArn(stackId)
    AND event.resourceType == "AWS::CloudFormation::Stack"
```

The AND requirement prevents nested-stack events from being mistaken for the top-level
stack's status.

**Terminal statuses** (all operations use the same set):
`CREATE_COMPLETE`, `CREATE_FAILED`, `DELETE_COMPLETE`, `DELETE_FAILED`,
`ROLLBACK_COMPLETE`, `ROLLBACK_FAILED`, `UPDATE_COMPLETE`,
`UPDATE_ROLLBACK_COMPLETE`, `UPDATE_ROLLBACK_FAILED`, `IMPORT_COMPLETE`,
`IMPORT_ROLLBACK_COMPLETE`, `IMPORT_ROLLBACK_FAILED`, `DELETE_SKIPPED`,
`REVIEW_IN_PROGRESS`.

Notable: `UPDATE_FAILED` is NOT terminal -- CFN auto-initiates rollback to
`UPDATE_ROLLBACK_COMPLETE` or `UPDATE_ROLLBACK_FAILED`.

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
- `CreateStack` is called exactly once per invocation.
- `OdStackDefinition` is emitted immediately after the stack is created, before polling
  begins (fetched via `DescribeStacks`). If the stack is not yet queryable (race
  condition), emission is silently skipped.
- `OdPollingStarted "Loading live events..."` is emitted before the polling loop starts.
- During polling, each batch of new events is emitted as `OdNewStackEvents` with
  per-event duration (seconds since operation start, minimum 1 second).
- `OdOperationComplete` is emitted when a terminal status is reached.
- On `DELETE_COMPLETE` (rollback caused stack deletion): return exit code 1 immediately
  without emitting `OdStackContents`.
- On poll timeout: return exit code 1 without emitting `OdStackContents` (stack may be
  partial).
- On any other terminal status: emit `OdStackContents` (resources, outputs, pending
  changesets), then return exit code 0 if final status is `CREATE_COMPLETE`, else 1.
- The primary client request token is used (not a derived token) to allow safe retries
  of the create call.

**Logic Flow:**

```pseudocode
createStack(ctx, args, argsfilePath):
  (req, token) = buildCreateStackRequest(ctx, args, usePrimary=True, argsfilePath)
  resp   = send(req)
  stackId = resp.stackId ?? args.stackName

  emitStackDefinition(ctx, stackId)     -- silently skipped if not yet queryable
  emit(OdPollingStarted "Loading live events...")

  pollResult = pollForCompletion(ctx, stackId, allTerminalStatuses, standardPollConfig)

  match pollResult:
    PollSuccess(DELETE_COMPLETE)  -> return exit 1
    PollSuccess(finalStatus)     ->
      contents = collectStackContents(ctx, args.stackName)
      emit(OdStackContents contents)
      return exit 0 if finalStatus == CREATE_COMPLETE else exit 1
    PollTimeout                  -> return exit 1
```

**Error Scenarios:**

- Template load failure: error returned before any AWS call.
- CloudFormation API error: propagated to the caller.
- `ROLLBACK_COMPLETE` terminal status: exit code 1 (create failed, stack remains).
- `DELETE_COMPLETE`: exit code 1 (create failed, stack cleaned up).

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
- All other AWS errors are re-thrown immediately (no catch-and-continue).
- On success: emit `OdStackDefinition`, emit `OdPollingStarted`, poll with
  `OdNewStackEvents` and `OdOperationComplete` callbacks, emit `OdStackContents`, return
  exit code 0 if `UPDATE_COMPLETE`, else 1.
- Stack ID is preferred from the `UpdateStackResponse`; falls back to `DescribeStacks`
  if absent.
- On poll timeout: return exit code 1 without emitting `OdStackContents`.

**Logic Flow:**

```pseudocode
updateStack(ctx, args, argsfilePath):
  (req, token) = buildUpdateStackRequest(ctx, args, usePrimary=True, argsfilePath)

  sendResult = try(send(req))
  match sendResult:
    Error(awsErr) where isNoUpdatesError(awsErr) ->
      emitStackDefinition(ctx, args.stackName)
      rethrow(awsErr)                -- top-level handler displays ValidationError; exit 1

    Error(awsErr) ->
      rethrow(awsErr)                -- all other errors propagated

    Success(resp) ->
      stackId = resp.stackId ?? getStackId(ctx, args.stackName) ?? args.stackName
      emitStackDefinition(ctx, stackId)
      emit(OdPollingStarted "Loading live events...")

      pollResult = pollForCompletion(ctx, stackId, allTerminalStatuses, standardPollConfig)
      match pollResult:
        PollSuccess(DELETE_COMPLETE) -> return exit 1
        PollSuccess(finalStatus)    ->
          contents = collectStackContents(ctx, args.stackName)
          emit(OdStackContents contents)
          return exit 0 if finalStatus == UPDATE_COMPLETE else exit 1
        PollTimeout                 -> return exit 1

isNoUpdatesError(err):
  err.code == "ValidationError"
    AND err.message contains "No updates are to be performed"
```

Error catching is applied ONLY to the UpdateStack API call, not to the polling phase.

---

### US-05-003: Update a stack via changeset

**As a** Platform Engineer or Reviewer, **I want to** preview changes to a stack before
applying them, **so that** destructive or unexpected changes are caught before execution.

**Acceptance Criteria:**

- Emit `OdStackDefinition` before creating the changeset (current stack state).
- Generate a deterministic changeset name: `"iidy-update-" + take(8, primaryToken)`.
- Create an `UPDATE` type changeset via the changeset creation flow (see US-05-006 for
  polling details).
- Emit `OdChangeSetResult` (includes console URL, pending changesets, next-steps text).
- If changeset status is `FAILED`: return `Left statusReason`; do not prompt.
- If changeset is valid: prompt for confirmation unless `--yes` flag is set.
  - User declines: return exit code 130.
- On confirmation: execute changeset (see exec-changeset flow); return exit code from
  execution.

**Logic Flow:**

```pseudocode
updateStackWithChangeset(ctx, args, yesFlag, argsfilePath):
  emitStackDefinition(ctx, args.stackName)

  csName = "iidy-update-" + take(8, primaryToken)
  info   = createChangeset(ctx, args, csName, stackExists=True, argsfilePath)
  result = buildChangeSetCreationResult(info, stackExisted=True, argsfilePath)
  emit(OdChangeSetResult result)

  if info.status == "FAILED":
    return error(info.statusReason ?? "Changeset creation failed")

  confirmation = confirmChangesetExecution(yesFlag)
  if confirmation == Declined:
    return exit 130

  return executeChangeset(ctx, args.stackName, csName)
```

**Edge Cases:**

- The changeset name is deterministic from the primary token prefix, so retrying the
  same invocation will attempt to reuse the same changeset name. CloudFormation returns
  an error if the name already exists.
- `OdChangeSetResult` is always emitted (even for `FAILED` changesets) so the user can
  see the failure reason and console URL.

---

### US-05-004: Delete a stack with confirmation

**As a** Developer or Platform Engineer, **I want to** safely delete a CloudFormation
stack with a clear confirmation step, **so that** accidental deletions are prevented in
interactive use while CI pipelines can skip the prompt with `--yes`.

**Acceptance Criteria:**

- If stack does not exist: call `GetCallerIdentity` (STS), emit `OdStackAbsentInfo`
  (stack name, environment, region, account ID, auth ARN), return exit code 0.
- If stack exists:
  - Emit `OdStackDefinition` (current state).
  - Emit `OdStackEvents` (previous 10 events, title `"Previous Stack Events (max 10):"`,
    with durations calculated from IN_PROGRESS/COMPLETE pairs).
  - Emit `OdStackContents` (current resources, outputs, pending changesets).
  - All three output sections are emitted BEFORE the confirmation prompt so the user
    has full context before deciding.
  - Unless `--yes` flag: prompt `"Are you sure you want to DELETE the stack <name>?"`.
    - User declines: return exit code 130.
  - Obtain stack ARN from the already-fetched stack object for reliable post-delete
    polling (stack name becomes invalid after deletion). If ARN is absent, fall back
    to stack name (best effort).
  - Send `DeleteStack` request with primary token.
  - Emit `OdPollingStarted "Loading live events..."`.
  - Poll until terminal status with `OdNewStackEvents` and `OdOperationComplete`
    callbacks.
  - Return exit code 0 if `DELETE_COMPLETE`, else 1.
  - On poll timeout: return exit code 1.

**Logic Flow:**

```pseudocode
deleteStack(ctx, stackName, skipConfirmation, env):
  mStack = getStack(ctx, stackName)

  if mStack is Nothing:
    (account, authArn) = getCallerIdentity(ctx.env)
    emit(OdStackAbsentInfo { stackName, env, region, account, authArn })
    return exit 0

  stack = mStack
  emit(OdStackDefinition (convertStack stack))
  events = fetchRecentStackEvents(ctx, stackName)
  emit(OdStackEvents (buildEventsDisplay 10 events))
  contents = collectStackContentsWithStack(ctx, stackName, Just stack)
  emit(OdStackContents contents)

  if not skipConfirmation:
    confirmation = requestConfirmation("Are you sure you want to DELETE the stack " + stackName + "?")
    if confirmation == Declined:
      return exit 130

  pollTarget = stack.stackId ?? stackName    -- prefer ARN for post-delete polling
  (req, token) = buildDeleteStackRequest(ctx, stackName)
  send(req)

  emit(OdPollingStarted "Loading live events...")
  pollResult = pollForCompletion(ctx, pollTarget, allTerminalStatuses, standardPollConfig)

  match pollResult:
    PollSuccess(finalStatus) ->
      return exit 0 if finalStatus in deleteSuccessStates else exit 1
    PollTimeout -> return exit 1
```

**Error Scenarios:**

- Stack absent: treated as success (idempotent delete), exit code 0.
- User declines: exit code 130.
- `DELETE_FAILED`: exit code 1, operator must investigate locked resources.
- AWS API error during delete: propagated as exception.

---

### US-05-005: Smart create-or-update routing

**As a** Developer or CI Pipeline, **I want to** run a single command that creates or
updates a stack depending on whether it already exists, **so that** the same command
works for both initial deployments and subsequent updates without branching in scripts.

**Acceptance Criteria:**

- Check stack existence before taking any action. `stackExists` treats
  `DELETE_COMPLETE` as absent (returns False even though the stack is still queryable).
- Route to one of four paths based on `(exists, useChangeset)`.
- The `--yes` flag is threaded through to all confirmation-requiring paths.
- Output emission sequences match those of the dispatched operation exactly.

**Decision tree:**

```pseudocode
createOrUpdate(ctx, args, useChangeset, yesFlag, argsfilePath):
  exists = stackExists(ctx, args.stackName)
    -- stackExists returns False for DELETE_COMPLETE stacks

  match (exists, useChangeset):
    (True,  False) -> updateStack(ctx, args, argsfilePath)
                      -- delegates to US-05-002; "no updates" error is
                      -- handled there (emits StackDefinition, re-throws)

    (True,  True)  -> updateWithChangeset(ctx, args, yesFlag, argsfilePath)
                      -- emitStackDefinition
                      -- csName = "iidy-create-or-update-" + take(8, primaryToken)
                      -- create UPDATE changeset -> confirm -> execute

    (False, False) -> createStack(ctx, args, argsfilePath)
                      -- delegates to US-05-001

    (False, True)  -> createWithChangeset(ctx, args, yesFlag, argsfilePath)
                      -- csName = generateDashedName()  -- random adjective-noun
                      -- create CREATE changeset
                      -- emitStackDefinition            -- stack now in REVIEW_IN_PROGRESS
                      -- confirm -> execute
```

**Changeset update path for existing stack:**

```pseudocode
updateWithChangeset(ctx, args, yesFlag, argsfilePath):
  emitStackDefinition(ctx, args.stackName)
  csName = "iidy-create-or-update-" + take(8, primaryToken)
  info   = createChangeset(ctx, args, csName, stackExists=True, argsfilePath)
  confirmAndExecuteChangeset(ctx, args.stackName, csName, info, yesFlag, argsfilePath, stackExisted=True)
```

**Changeset create path for new stack:**

```pseudocode
createWithChangeset(ctx, args, yesFlag, argsfilePath):
  csName = generateDashedName()        -- random adjective-noun from 20x20=400 vocabulary
  info   = createChangeset(ctx, args, csName, stackExists=False, argsfilePath)
  emitStackDefinition(ctx, args.stackName)   -- stack now exists in REVIEW_IN_PROGRESS
  confirmAndExecuteChangeset(ctx, args.stackName, csName, info, yesFlag, argsfilePath, stackExisted=False)
```

**Shared confirm-and-execute helper:**

```pseudocode
confirmAndExecuteChangeset(ctx, stackName, csName, info, yesFlag, argsfile, stackExisted):
  result = buildChangeSetCreationResult(info, stackExisted, argsfile)
  emit(OdChangeSetResult result)
  if info.status == "FAILED":
    return error(info.statusReason ?? "Changeset creation failed")
  confirmation = confirmChangesetExecution(yesFlag)
  if confirmation == Declined:
    return exit 130
  return executeChangeset(ctx, stackName, csName)
```

**Edge Cases:**

- Random changeset names for the CREATE path use a 20-adjective x 20-noun vocabulary
  (Docker-style names like `"admiring-albattani"`).
- For the CREATE changeset path: after the changeset is created, the stack exists in
  `REVIEW_IN_PROGRESS`; the stack definition is fetched and emitted at that point.
- The update-via-changeset changeset name prefix differs between update-stack
  (`"iidy-update-"`) and create-or-update (`"iidy-create-or-update-"`). These are
  distinct to avoid naming conflicts when both paths are used with the same token.

---

### US-05-006: Create and execute changesets independently

**As a** Reviewer or Platform Engineer, **I want to** create a changeset without
immediately executing it, and separately execute a named changeset, **so that** change
review and deployment can be performed as separate steps with different approvers.

**Acceptance Criteria (create-changeset):**

- Accept a changeset name from the user or generate a deterministic/random name.
- Determine changeset type (`CREATE` or `UPDATE`) based on stack existence.
- Call `CreateChangeSet` API with a derived token (step name `"create-changeset"`).
- Poll `DescribeChangeSet` every 2 seconds until a terminal status is reached.
- Emit `OdChangeSetResult` with:
  - Changeset name, stack name, type (`CREATE` or `UPDATE`).
  - Console URL with percent-encoded ARNs (see URL format below).
  - `hasChanges` flag (based on whether changes list is non-empty).
  - Next-steps text differs by changeset type:
    - CREATE: includes `"Your new stack is now in REVIEW_IN_PROGRESS state"` explanation
      line, then the exec-changeset CLI command.
    - UPDATE: only the exec-changeset CLI command (no REVIEW_IN_PROGRESS line).
- Return the `ChangeSetInfo` to the caller (for further action in other paths).

**Changeset polling with retry logic:**

```pseudocode
pollChangesetCompletion(ctx, stackName, csId):
  errorCount     = 0
  totalIterations = 0
  maxRetries     = 30        -- transient error budget (60 seconds at 2s interval)
  maxIterations  = 300       -- overall cap (600 seconds / 10 minutes)

  loop:
    if totalIterations >= maxIterations:
      return syntheticFailedInfo("timed out after 300 iterations")

    sleep(2 seconds)
    result = describeChangeset(ctx, stackName, csId)

    match result:
      Error(err) where isNonRetryableError(err) ->
        return syntheticFailedInfo(formatError(err))
        -- Non-retryable: ChangeSetNotFoundException, AccessDeniedException, ValidationError

      Error(err) where errorCount >= maxRetries ->
        return syntheticFailedInfo("failed after 30 retries: " + formatError(err))

      Error(err) ->
        errorCount += 1
        totalIterations += 1
        continue

      Success(info) ->
        if info.status in ["CREATE_COMPLETE", "FAILED", "DELETE_COMPLETE", "DELETE_FAILED"]:
          return info
        errorCount = 0        -- reset on success
        totalIterations += 1
        continue
```

**Acceptance Criteria (exec-changeset):**

- Derive an `execute-changeset` token from the primary token.
- Call `ExecuteChangeSet` API.
- Get stack ARN for polling (fall back to stack name if unavailable).
- Emit `OdStackDefinition` (current stack state after execution start).
- Emit `OdStackEvents` with title `"Previous Stack Events (max 10):"` (pre-existing
  events, max 10, with durations from IN_PROGRESS/COMPLETE pairs).
- Emit `OdPollingStarted "Loading live events..."`.
- Poll until terminal status with `OdNewStackEvents` and `OdOperationComplete` callbacks.
- On `DELETE_COMPLETE`: return exit code 1 without emitting `OdStackContents`.
- On any other terminal status: emit `OdStackContents`.
- Return exit code 0 if final status is `CREATE_COMPLETE` or `UPDATE_COMPLETE`, else 1.
- On poll timeout: return exit code 1.

**Logic Flow (exec-changeset):**

```pseudocode
executeChangeset(ctx, stackName, csName):
  token = deriveToken(ctx, "execute-changeset")
  req   = ExecuteChangeSet { changeSetName=csName, stackName, clientRequestToken=token }
  send(req)

  stackId = getStackId(ctx, stackName) ?? stackName
  emitStackDefinition(ctx, stackId)

  prevEvents = fetchRecentStackEvents(ctx, stackName)
  emit(OdStackEvents (buildEventsDisplay 10 prevEvents))
  emit(OdPollingStarted "Loading live events...")

  pollResult = pollForCompletion(ctx, stackId, allTerminalStatuses, standardPollConfig)

  successStates = [CREATE_COMPLETE, UPDATE_COMPLETE]
  match pollResult:
    PollSuccess(DELETE_COMPLETE) -> return exit 1
    PollSuccess(finalStatus)    ->
      emit(OdStackContents (collectStackContents ctx stackName))
      return exit 0 if finalStatus in successStates else exit 1
    PollTimeout                 -> return exit 1
```

**URL formats:**

| URL type        | Format                                                                                              | ARN encoding    |
|-----------------|-----------------------------------------------------------------------------------------------------|-----------------|
| Changeset       | `https://<region>.console.aws.amazon.com/cloudformation/home?region=<region>#/changeset/detail?stackId=<encoded>&changeSetId=<encoded>` | Percent-encoded |
| Stack info      | `https://<region>.console.aws.amazon.com/cloudformation/home?region=<region>#/stacks/stackinfo?stackId=<encoded>`                       | Percent-encoded |

Region for the console URL is extracted from the stack ARN
(`arn:aws:cloudformation:REGION:...`). Malformed ARNs fall back to `us-east-1`.

---

### US-05-007: Describe stack state

**As a** Developer or Platform Engineer, **I want to** inspect the current state of a
stack including its definition, recent events, resources, and outputs, **so that** I can
understand what was deployed, the current health, and what resources exist.

**Acceptance Criteria:**

- Accept a `--num-events` parameter (default N) controlling how many events are shown.
- If stack does not exist: call `GetCallerIdentity` (STS), emit `OdStackAbsentInfo`
  (stack name, environment, region, account, auth ARN), return `Right ()`.
- If stack exists: emit `OdStackDefinition`, `OdStackEvents`, `OdStackContents` in that
  order.
- `OdStackEvents` title format: `"Previous Stack Events (max <N>):"`.
- Event durations use the historical pairing algorithm (see below).
- `OdStackContents` includes resources (from `DescribeStackResources`), outputs (from
  `DescribeStacks`), pending changesets (from `ListChangeSets`), and exports (derived
  from outputs with export names). Resources and changesets are fetched concurrently.
- `StackDefinition.sdStacksetName` is populated from the `"StackSetName"` tag if present.
- Events are fetched across multiple pages until at least `numEvents * 2` events are
  collected or all pages are exhausted.

**Historical event duration calculation:**

```pseudocode
calculateEventDurations(events):
  sorted   = sortChronologically(events)    -- oldest first
  startMap = {}                             -- key -> timestamp

  for each event in sorted:
    key = event.logicalResourceId + "/" + event.resourceType
    statusText = toText(event.resourceStatus)

    if statusText ends with "_IN_PROGRESS":
      startMap[key] = event.timestamp
      event.duration = None

    else if statusText ends with "_COMPLETE" or "_FAILED":
      if key in startMap:
        event.duration = max(1, floor(event.timestamp - startMap[key]))
      else:
        event.duration = None

    else:
      event.duration = None

  return events in original order with durations attached
```

If an event has no timestamp, its duration is `Nothing` (no error raised).

**Logic Flow:**

```pseudocode
describeStack(ctx, stackName, numEvents, env):
  mStack = getStack(ctx, stackName)

  if mStack is Nothing:
    (account, authArn) = getCallerIdentity(ctx.env)
    emit(OdStackAbsentInfo { stackName, env, region, account, authArn })
    return Right(())

  stack  = mStack
  events = fetchStackEventsUpTo(ctx, stackName, numEvents)
  contents = collectStackContentsWithStack(ctx, stackName, Just stack)
  emit(OdStackDefinition (convertStack stack))
  emit(OdStackEvents (buildEventsDisplay numEvents events))
  emit(OdStackContents contents)
  return Right(())
```

**Error Scenarios:**

- Stack absent: treated as a non-error (emits `OdStackAbsentInfo`, exits 0); the STS
  call provides auth context to help diagnose wrong region/account issues.

---

### US-05-008: Watch stack events in real-time

**As a** Developer or CI Pipeline, **I want to** observe the event stream of an
in-progress stack operation and follow it until completion, **so that** I can monitor
deployments initiated by other tools (console, other scripts) without polling manually.

**Acceptance Criteria:**

- If stack does not exist: return `Left "Stack not found: <name>"` (non-zero exit).
- If stack exists:
  - Emit `OdStackDefinition`.
  - Obtain stable stack ARN from the already-fetched stack object (no extra API call).
  - Fetch initial events; emit `OdStackEvents` (previous 10, with historical durations).
  - Record the set of initial event IDs for deduplication.
  - Emit `OdPollingStarted "Loading live events..."`.
  - Poll with `waitForStatusChange = True`: do not exit on a terminal status until at
    least one new event has been observed. This is implemented by filtering to events
    with `timestamp > startTime` for terminal status checks.
  - Apply two-layer deduplication: the poll loop's own seen-set PLUS a filter against
    the initial event ID set.
  - Emit `OdNewStackEvents` for each batch of genuinely new events.
  - Emit `OdOperationComplete` when a terminal status is reached.
  - If inactivity timeout is configured and triggers (after events have been seen):
    emit `OdInactivityTimeout`.
  - If final status is `DELETE_COMPLETE`: return `Right 0` without emitting
    `OdStackContents`.
  - Otherwise: emit `OdStackContents`, return `Right 0`.
  - Once polling begins, always exit 0 (watch merely observes; it does not judge
    success/failure of the underlying operation). Stack-not-found exits non-zero.

**Inactivity timeout logic:**

```pseudocode
-- Inactivity timeout fires only when ALL conditions are met:
timeout > 0
  AND newEvents is empty (this poll cycle)
  AND (now - lastEventTime) > timeout
  AND (waitForStatusChange == False OR hasSeenNewEvents == True)
```

**Logic Flow:**

```pseudocode
watchStack(ctx, stackName, timeoutSeconds):
  mStack = getStack(ctx, stackName)
  if mStack is Nothing:
    return error("Stack not found: " + stackName)

  stack   = mStack
  stackId = stack.stackId ?? stackName

  emit(OdStackDefinition (convertStack stack))
  initialEvents = fetchRecentStackEvents(ctx, stackId)
  emit(OdStackEvents (buildEventsDisplay 10 initialEvents))
  seenIds = Set.fromList(map eventId initialEvents)

  emit(OdPollingStarted "Loading live events...")

  pollConfig = standardPollConfig {
    waitForStatusChange = True,
    inactivityTimeoutSecs = if timeoutSeconds > 0 then Just timeoutSeconds else Nothing,
    onNewEvents = \newEvents ->
      let fresh = filter (\e -> e.eventId not in seenIds) newEvents
      if fresh not empty: emit(OdNewStackEvents (convertWithDurations fresh)),
    onInactivityTimeout = emit . OdInactivityTimeout
  }

  pollResult = pollForCompletion(ctx, stackId, allTerminalStatuses, pollConfig)

  match pollResult:
    PollSuccess(DELETE_COMPLETE) -> return exit 0
    _other                       ->
      emit(OdStackContents (collectStackContents ctx stackName))
      return exit 0
```

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
  - **Safety timeout:** Cap polling at 100 iterations (5 minutes). On timeout, emit
    `OdStatusUpdate` with message `"Drift detection timed out after N minutes. Results
    may be incomplete."`, level `LevelWarning`. **(Diverges from Rust, which polls
    indefinitely.)**
- Collect drift results via paginated `DescribeStackResourceDrifts`.
- Filter out `IN_SYNC` resources; only drifted resources are included.
- Emit `OdStackDrift` with the list of drifted resource records (logical ID, physical
  ID, resource type, drift status, property differences).

**Drift cache check logic:**

```pseudocode
needsDriftCheck(stack, cacheSecs):
  driftInfo = stack.driftInformation
  if driftInfo is Nothing: return True
  if driftInfo.stackDriftStatus == NOT_CHECKED: return True
  if driftInfo.lastCheckTimestamp is Nothing: return True
  elapsed = now - driftInfo.lastCheckTimestamp
  return elapsed > cacheSecs
```

**Logic Flow:**

```pseudocode
describeStackDrift(ctx, stackName, driftCacheSecs):
  mStack = getStack(ctx, stackName)
  if mStack is Nothing:
    return error("Stack not found: " + stackName)

  emit(OdStackDefinition (convertStack mStack))

  if needsDriftCheck(mStack, driftCacheSecs):
    emit(OdStatusUpdate "Checking for stack drift..." LevelInfo)
    detectionId = send(DetectStackDrift stackName).stackDriftDetectionId

    completed = pollDriftDetection(ctx, maxIterations=100, detectionId)
    if not completed:
      timeoutMins = (100 * 3) / 60
      emit(OdStatusUpdate "Drift detection timed out after {timeoutMins} minutes..." LevelWarning)

  driftData = collectAllDriftPages(ctx, stackName)
  driftedOnly = filter(not IN_SYNC, driftData)
  emit(OdStackDrift { driftedResources = map(convertDrift, driftedOnly) })
  return Right(())
```

**Error Scenarios:**

- Stack not found: error returned.
- Drift detection API error: propagated as exception.
- All resources are `IN_SYNC`: `OdStackDrift` emitted with empty drifted resources list.

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
- `OdPollingStarted` is emitted before polling begins in every write operation.
- `OdOperationComplete.skipRemainingSections` is True when the terminal status is
  `DELETE_COMPLETE` -- renderers use this flag to suppress further output sections.
- The spinner displays braille frames at 100ms intervals, with timing text updated
  every 1 second showing total elapsed and time since last event.

**Poll configuration:**

| Field                   | Default          | Description                                               |
|-------------------------|------------------|-----------------------------------------------------------|
| intervalSeconds         | 2                | Sleep between poll cycles                                 |
| timeoutSeconds          | None             | Overall timeout; returns PollTimeout on expiry            |
| inactivityTimeoutSecs   | None             | Inactivity timeout; only fires after events seen          |
| waitForStatusChange     | False            | True only for watch-stack                                 |
| onNewEvents             | noop             | Callback receiving events in chronological order          |
| onOperationComplete     | noop             | Callback with elapsed, start time, skipRemainingSections  |
| onInactivityTimeout     | noop             | Callback with timeout info                                |
| onPollTick              | noop             | Called each cycle (for spinner)                           |

**Inner poll loop:**

```pseudocode
pollForCompletion(fetchEvents, stackId, terminalStatuses, config):
  startTime       = config.startTime ?? now()
  lastEventTime   = startTime
  hasSeenNewEvents = False
  lastEventSet    = {}       -- starts empty; first poll sees all pre-existing events

  loop:
    sleep(config.intervalSeconds)
    config.onPollTick()
    events    = fetchEvents()
    now       = currentTime()
    newEvents = filter(\e -> e.eventId not in lastEventSet, events)

    if newEvents not empty:
      lastEventTime    = now
      hasSeenNewEvents = True
      config.onNewEvents(reverse(newEvents))    -- reverse: AWS returns most-recent-first

    -- Check inactivity timeout
    inactivityElapsed = now - lastEventTime
    if config.inactivityTimeoutSecs is Just(timeout)
       AND timeout > 0
       AND newEvents is empty
       AND inactivityElapsed > timeout
       AND (not config.waitForStatusChange OR hasSeenNewEvents):
      config.onInactivityTimeout(...)
      return PollInactivityTimeout

    -- Check overall timeout
    totalElapsed = now - startTime
    if config.timeoutSeconds is Just(t) AND t > 0 AND totalElapsed > t:
      return PollTimeout

    -- Check terminal status
    stackEvents = filter(isStackEvent(_, stackId), events)
    relevantStackEvents =
      if config.waitForStatusChange:
        filter(\e -> e.timestamp > startTime, stackEvents)
      else:
        stackEvents
    currentStatus = head(relevantStackEvents).resourceStatus    -- most recent

    if currentStatus in terminalStatuses:
      config.onOperationComplete(OperationCompleteInfo {
        elapsedSeconds      = now - startTime,
        startTime           = startTime,
        skipRemainingSections = (currentStatus == DELETE_COMPLETE)
      })
      return PollSuccess(currentStatus)

    lastEventSet = lastEventSet UNION Set.fromList(map eventId newEvents)
    continue
```

**Live event duration calculation:**

```pseudocode
convertEventWithDuration(startTime, event):
  duration = max(1, floor(event.timestamp - startTime))
  return StackEventWithTiming { event, duration }
```

`startTime` is `cfnStartTime` from the context (set at context creation, not at first
event).

**Edge Cases:**

- New events are delivered to the callback in chronological order (reversed from AWS
  response which is most-recent-first).
- `lastEventSet` is updated incrementally with new event IDs (union, not replace).
- When `waitForStatusChange` is True, only events with `timestamp > startTime` are
  considered for terminal exit. Pre-existing terminal events are displayed but do not
  trigger exit.

**Error Scenarios:**

- AWS errors during polling: propagated as exceptions (not caught within the loop).
- Overall timeout: returns `PollTimeout`; operations treat this as exit code 1.
- Inactivity timeout: returns `PollInactivityTimeout`; `OdInactivityTimeout` emitted
  first.

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
  - Error catching is applied ONLY to the UpdateStack API call; all other errors are
    also re-thrown (there is no catch-and-continue path).
- Stack absent in delete-stack: emit `OdStackAbsentInfo` with STS caller identity
  (account ID, ARN); exit code 0 (idempotent).
- Stack absent in describe-stack: emit `OdStackAbsentInfo` with STS caller identity;
  return `Right ()`.
- Stack absent in watch-stack: return `Left "Stack not found: <name>"` (non-zero exit).
- Changeset `FAILED` status: return `Left statusReason`; do not proceed to execution.
- `FAILED` changeset check uses exact string equality on the status field.
- All unrecognized AWS errors: propagated as exceptions to the top-level handler.
- Tag values in `StackArgs` must be `Text` (strings); non-string YAML values in argsfiles
  (e.g., bare integers) are rejected with a descriptive error before any API call.
- Stack definition fetch (`emitStackDefinition`) silently does nothing if the stack is
  not found. This applies in all write operations that call it.
- Stack existence check via `getStack` catches `ValidationError` containing `"does not
  exist"` and returns absent; other errors are re-thrown.

**Terminal statuses** -- all operations use `allTerminalStatuses` (the full set of
terminal statuses from the StackStatus ADT). See "Stack Status Detection" section above
for the complete list.

**Success states per operation:**

| Operation        | Success states                               |
|------------------|----------------------------------------------|
| create-stack     | `CREATE_COMPLETE`                            |
| update-stack     | `UPDATE_COMPLETE`                            |
| delete-stack     | `DELETE_COMPLETE`                            |
| exec-changeset   | `CREATE_COMPLETE`, `UPDATE_COMPLETE`         |

**Edge Cases:**

- Event duration minimum is 1 second: `max(1, floor(end - start))`.
- `stackExists` returns `False` for `DELETE_COMPLETE` stacks (not just absent stacks).
  The distinction matters: existence is used for routing; the definition fetch still
  succeeds for such stacks.

**Error Scenarios:**

- Lint: template > 51199 bytes emits a warning and skips validation; no error exit.
- Estimate-cost: template load failure returns an error.
- Describe-stack-drift: stack not found returns an error; drift detection errors
  propagated as exceptions.

---

### US-05-012: Idempotent operations via tokens

**As a** CI Pipeline, **I want to** safely retry failed CloudFormation operations using
client request tokens, **so that** network failures or timeouts do not result in
duplicate resources.

**Acceptance Criteria:**

- All write operations accept an optional `--client-request-token` CLI flag.
- If not provided, a UUID is generated at startup and used as the primary token.
- The primary token is used directly for single-step operations (CreateStack, UpdateStack,
  DeleteStack).
- Multi-step operations derive per-step tokens deterministically.
- Derived tokens are tracked for the command metadata summary.
- Changeset names are deterministic from the token prefix:
  - update-stack path: `"iidy-update-"` + first 8 chars of primary token
  - create-or-update update path: `"iidy-create-or-update-"` + first 8 chars of primary
    token
  - create-or-update create path: random adjective-noun name (non-deterministic)
- The primary token is a UUID string; the "first 8 chars" refers to the first 8
  characters of that UUID.

**Token derivation:**

```pseudocode
deriveTokenForStep(primaryToken, stepName):
  input    = encode_utf8(primaryToken.value + stepName)     -- direct concatenation, NO separator
  digest   = SHA256(input)
  hashHex  = lowercase(hex(digest))
  prefix   = take(8, primaryToken.value)
  suffix   = take(8, hashHex)
  return TokenInfo {
    value  = prefix + "-" + suffix,                         -- e.g. "a1b2c3d4-e5f6g7h8"
    source = Derived { from=primaryToken.value, step=stepName }
  }
```

**Token usage by operation:**

| Operation        | Token                                        | Step name               |
|------------------|----------------------------------------------|-------------------------|
| CreateStack      | Primary (direct)                             | --                      |
| UpdateStack      | Primary (direct)                             | --                      |
| DeleteStack      | Primary (direct)                             | --                      |
| CreateChangeSet  | Derived                                      | `"create-changeset"`    |
| ExecuteChangeSet | Derived                                      | `"execute-changeset"`   |

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

**Token tracking:**

All used tokens (primary and derived) are tracked and included in the `OdCommandMetadata`
output event so the operator can reference them for CloudFormation console lookups and
retries. Tokens are returned in forward-chronological order.

---

### US-05-013: List stacks

**As a** Developer or Platform Engineer, **I want to** list all CloudFormation stacks
in the current region with optional tag filtering, **so that** I can discover and
identify stacks without navigating the AWS console.

**Acceptance Criteria:**

- Fetch all stacks via paginated `DescribeStacks`.
- Apply optional `key=value` tag filters. A stack must match ALL supplied filters.
- Tag filter parsing: split on first `=`; if no `=`, entire string is the key with
  empty value. Matching is exact: `Map.lookup key tagMap == Just value`.
- Sort results by creation time (oldest first).
- Emit `OdStackList` with entries containing: stack name, status, creation time, last
  updated time, tags, status reason, termination protection, environment type (from
  `iidy:environment` tag).
- Column selection: include tags column when filters are active or `--tags` is requested.

---

### US-05-014: Get stack template

**As a** Developer, **I want to** retrieve the current template body of a deployed stack,
**so that** I can inspect what CloudFormation is actually using.

**Acceptance Criteria:**

- Call `GetTemplate` with the stack name.
- Return the template body text (empty string if absent).
- No additional processing or validation.

---

### US-05-015: Estimate template cost

**As a** Developer, **I want to** get a cost estimate URL for a CloudFormation template,
**so that** I can understand the monthly cost before deploying.

**Acceptance Criteria:**

- Load the template via the standard template loading pipeline.
- Call `EstimateTemplateCost` with the loaded template body and/or URL.
- Emit `OdCostEstimate` with the AWS Simple Monthly Calculator URL, stack name, and
  template file path.
- Return exit code 0.

---

### US-05-016: Lint (validate) template

**As a** Developer, **I want to** validate a CloudFormation template against the AWS API
before deploying, **so that** syntax errors are caught early.

**Acceptance Criteria:**

- Load the template via the standard template loading pipeline.
- If the template body exceeds 51199 bytes: emit a `TemplateValidation` with a warning
  message (`"Template exceeds 51200 bytes; skipping CFN validation"`), no errors. Return
  exit code 0.
- If the template body is within limits: call `ValidateTemplate` API.
  - On success: emit `TemplateValidation` with no errors, no warnings. Return exit code 0.
  - On API error: emit `TemplateValidation` with the error message. Return exit code 1.

---

### US-05-017: Convert existing stack to iidy format

**As a** Developer, **I want to** convert an existing CloudFormation stack into
iidy-compatible YAML files, **so that** I can adopt iidy for managing pre-existing
infrastructure.

**Acceptance Criteria:**

- Fetch the stack's template (`GetTemplate`), metadata (`DescribeStacks`), and policy
  (`GetStackPolicy`).
- Create an output directory with:
  - `stack-policy.json`: Pretty-printed JSON (fallback to default allow-all policy).
  - `_original-template.<ext>`: Original template body (extension matches JSON/YAML).
  - `cfn-template.yaml`: Template converted to sorted YAML.
  - `stack-args.yaml`: Generated argsfile with parameterized stack name, `$defs`,
    `$imports`, parameters, tags, capabilities, and other settings.
- Template YAML sorting uses context-dependent weight functions:

  | Context                              | Sort order                                                  |
  |--------------------------------------|-------------------------------------------------------------|
  | Top-level document                   | AWSTemplateFormatVersion, Description, ..., Resources, Outputs |
  | Parameters block                     | Description, Type, MinValue, MaxValue, MinLength, MaxLength |
  | Resources block                      | Type first, Properties last                                 |
  | Outputs block                        | Description, Value, Export                                  |
  | Tags                                 | Key, Value                                                  |
  | IAM Statement                        | Sid, Effect, Action, Resource, Condition                    |
  | PolicyDocument/AssumeRolePolicyDocument | Version, Statement                                        |
  | Policies                             | PolicyName, PolicyDocument                                  |

- Stack name parameterization: replaces known environment names with `{{environment}}`,
  trailing digits with `{{build_number}}`, and project name with `{{project}}`.
- Optional `--move-params-to-ssm`: migrates non-environment parameters to SSM
  SecureString at path `/{environment}/{project}/{ParameterName}`. Parameters are
  written serially. Failures on individual parameters are logged to stderr but do not
  abort the operation.
- Sorting can be disabled with a `--no-sort-keys` flag.
- Return exit code 0 on success.

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
- Stack console URL building is unit-tested for URL format and percent-encoding.
- Region extraction from ARN is unit-tested with standard and malformed ARNs.
- Integration tests verify the complete `OdStackDefinition -> OdStackEvents ->
  OdStackContents` emission sequence for describe-stack.
- Changeset polling retry logic is tested: transient retries, non-retryable errors,
  overall timeout.
- All AWS calls are mocked via the context dependency; no real AWS credentials are
  required in the test suite.
- 100% of tests must pass before any commit. No test stubs, no skipped assertions.

## Cross-References

- `06-output-system.md` -- all `OutputData` event types emitted by operations
- `08-aws-integration.md` -- credential chain, region resolution, NTP time provider
- `07-error-handling.md` -- error display pipeline that surfaces AWS errors
- `DIVERGENCES.md` -- known behavioral differences from Rust (drift detection timeout)
- Rust oracle: `~/src/iidy/src/cfn/` (read-only reference)
