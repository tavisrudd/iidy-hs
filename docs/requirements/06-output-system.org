# PRD: Output System

## Overview

iidy-hs routes all command output through a unified pipeline that supports three distinct
rendering modes: interactive (color, spinners, formatted sections), plain (no ANSI, no
spinners, log-friendly), and json (JSON Lines / NDJSON, one object per line). Every
structured value emitted by a command is represented as one of 27 `OutputData` variants.
The pipeline selects the appropriate renderer at startup based on CLI flags, terminal
detection, and environment variables, then passes each `OutputData` value to the renderer
in order.

The output system is the sole path by which human-readable or machine-readable output
reaches the terminal. No command implementation writes directly to stdout or stderr (with
the exception of the param subcommands, which predate the pipeline). Behavioral parity with
the Rust iidy binary is the acceptance standard for interactive and plain modes; the JSON
renderer defines its own stable schema.

## Technical Context

All ANSI escape codes are emitted directly (no third-party terminal library abstraction
visible to callers). Themes are pure data records; switching themes does not require
re-initializing the renderer. JSON serialization uses an envelope format (type,
timestamp, data) defined in this PRD. The interactive and plain modes share the same
rendering code path; plain mode is controlled by a boolean flag that turns all
color/bold calls into no-ops.

### OutputData Type Declaration

The `OutputData` type has exactly 27 constructors covering all output events:

```
type OutputData
    = OdCommandMetadata      CommandMetadata
    | OdStackDefinition      StackDefinition Bool       -- Bool = show_times flag
    | OdStackEvents          StackEventsDisplay
    | OdStackContents        StackContents
    | OdStatusUpdate         StatusUpdate
    | OdCommandResult        CommandResult
    | OdFinalCommandSummary  FinalCommandSummary
    | OdStackList            StackListDisplay
    | OdChangeSetResult      ChangeSetCreationResult
    | OdStackDrift           StackDrift
    | OdError                ErrorInfo
    | OdTokenInfo            TokenInfo
    | OdNewStackEvents       [StackEventWithTiming]
    | OdOperationComplete    OperationCompleteInfo
    | OdInactivityTimeout    InactivityTimeoutInfo
    | OdConfirmationPrompt   ConfirmationRequest
    | OdStackChangeDetails   StackChangeDetails
    | OdStackAbsentInfo      StackAbsentInfo
    | OdCostEstimate         CostEstimate
    | OdStackTemplate        StackTemplate
    | OdApprovalRequestResult ApprovalRequestResult
    | OdTemplateValidation   TemplateValidation
    | OdApprovalStatus       ApprovalStatus
    | OdTemplateDiff         TemplateDiff
    | OdApprovalResult       ApprovalResult
    | OdPollingStarted       Text                       -- spinner message
    | OdRawOutput            Text                       -- raw text for non-CFN commands
```

### TTY Detection and Mode Resolution

Terminal capabilities are detected at startup:

```
detectCapabilities:
    isTty    = hIsTerminalDevice stdout
    noColor  = lookupEnv "NO_COLOR"
    forceColor = lookupEnv "FORCE_COLOR"
    columns  = lookupEnv "COLUMNS"

    hasColor = case (noColor, forceColor) of
        (Just _, _)      -> False    -- NO_COLOR takes precedence
        (_, Just _)      -> True     -- FORCE_COLOR forces on
        (Nothing,Nothing)-> isTty    -- auto-detect

    width = parse COLUMNS or default 80 if TTY, Nothing if not

    return TerminalCapabilities { tcHasColor, tcWidth, tcIsTty }
```

The output mode is then resolved:

```
resolveMode:
    --output-mode json        -> OutputJson
    --output-mode plain       -> OutputPlain
    --output-mode interactive -> OutputInteractive
    no flag + TTY             -> OutputInteractive
    no flag + not TTY         -> OutputPlain

resolveColors(colorFlag, mode, capabilities):
    ColorAlways -> True
    ColorNever  -> False
    ColorAuto   -> case mode of
        OutputJson        -> False   -- JSON always disables color
        OutputPlain       -> False   -- Plain always disables color
        OutputInteractive -> tcHasColor capabilities

resolveTheme(colorsEnabled, themeChoice):
    if not colorsEnabled -> noColorTheme   -- all fields = AnsiDefault
    ThemeAuto            -> darkTheme
    ThemeDark            -> darkTheme
    ThemeLight           -> lightTheme
    ThemeHighContrast    -> highContrastTheme
```

### Theme Color Definitions

Four themes are defined. Each theme is a record of 14 color fields:

| Field              | Dark Theme            | Light Theme            | High-Contrast       | No-Color    |
|--------------------|-----------------------|------------------------|----------------------|-------------|
| thColorsEnabled    | True                  | True                   | True                 | False       |
| thTimestamp        | Rgb 212 212 212       | Rgb 105 105 105        | BrightWhite          | AnsiDefault |
| thResourceId       | Rgb 198 198 198       | Rgb 70 70 70           | BrightCyan           | AnsiDefault |
| thSectionHeading   | Rgb 238 238 238       | AnsiBlack              | BrightWhite          | AnsiDefault |
| thMuted            | Rgb 128 128 128       | Rgb 105 105 105        | AnsiWhite            | AnsiDefault |
| thPrimary          | AnsiMagenta           | Rgb 163 21 21          | BrightMagenta        | AnsiDefault |
| thSuccess          | AnsiGreen             | Rgb 34 139 34          | BrightGreen          | AnsiDefault |
| thError            | AnsiRed               | Rgb 220 20 60          | BrightRed            | AnsiDefault |
| thWarning          | AnsiYellow            | Rgb 255 140 0          | BrightYellow         | AnsiDefault |
| thInfo             | AnsiWhite             | Rgb 70 130 180         | BrightWhite          | AnsiDefault |
| thSkipped          | Rgb 88 88 88          | Rgb 169 169 169        | BrightBlack          | AnsiDefault |
| thEnvProduction    | AnsiRed               | Rgb 220 20 60          | BrightRed            | AnsiDefault |
| thEnvIntegration   | Rgb 95 175 255        | Rgb 70 130 180         | BrightBlue           | AnsiDefault |
| thEnvDevelopment   | Rgb 215 255 215       | Rgb 218 165 32         | BrightYellow         | AnsiDefault |

---

## User Stories

---

### US-06-001: View interactive output with themes and colors

**As a** Developer, **I want to** receive richly formatted, color-coded output in my
terminal when running iidy commands interactively, **so that** I can quickly scan stack
names, statuses, and section headers without reading plain text.

**Acceptance Criteria:**

- When stdout is a TTY and `--output-mode` is absent, the interactive renderer is selected
  automatically.
- Section headings are rendered as bold text in `thSectionHeading` color followed by `:`,
  preceded by a blank line (except the first section).
- Each entry is formatted as ` <label_padded_to_25_chars> <value>`, where label text is in
  `thMuted` color and value text receives semantic coloring (status, environment, resource
  ID, timestamp, etc.).
- Column alignment: `column2Start = 25`; labels exceeding 25 characters are truncated or
  the value is placed after a single space.
- Dynamic padding for tabular sections (stack events, stack resources, etc.) is computed
  by scanning the full list and taking the maximum text width of each column, clamped
  between `minStatusPadding = 17` and `maxPadding = 60`. Resource type columns use a
  separate `resourceTypePadding = 40` constant. Default screen width is 80 columns.
- Timestamps use the format `%a %b %d %Y %H:%M:%S` (e.g., `Tue Feb 22 2026 14:30:00`).
- CloudFormation resource status values are colored semantically:
  - Substring `IN_PROGRESS` -> `thWarning` (yellow in dark theme)
  - Substring `COMPLETE` -> `thSuccess` (green)
  - Substring `FAILED` -> `thError` (red)
  - `DELETE_SKIPPED` -> `thSkipped` (dark gray)
  - All other values -> `thInfo` (white)
- Environment name values (`production`, `integration`, `development`) are colored via
  `colorByEnvironment`: production -> `thEnvProduction` (red), integration ->
  `thEnvIntegration` (blue), development -> `thEnvDevelopment` (green). Unrecognized
  environment names are rendered without color.
- The stack list uses lifecycle icons derived from the `lifetime` tag:
  - Termination-protected stacks (`sleTerminationProtection = True`) or
    `lifetime=protected` tag: show lock icon.
  - `lifetime=long` tag: show infinity symbol.
  - `lifetime=short` tag: show recycle symbol.
- Final command summary in interactive mode:
  - `SummarySuccess`: green background + black text "Success" with thumbs-up emoji,
    rendered as a section entry under "Command Summary:".
  - `SummaryFailure`: red background + white text "Failure" with table-flip emoticon,
    followed by "Fix and try again." on its own line.
- `OdTokenInfo` and `OdPollingStarted` produce no visible output in interactive mode
  (internal lifecycle signals only).
- `OdRawOutput` passes raw text directly to stdout without any formatting, padding,
  or section structure. Used for non-CloudFormation command output.

**Logic Flow:**

1. The output dispatcher detects TTY and resolves mode to interactive.
2. The active theme is selected from the color-enabled flag and theme choice.
3. Each output event is rendered by pattern-matching on the `OutputData` variant.
4. Section helpers emit a bold heading + `:`, then iterate entries.
5. Resource status coloring and environment coloring are applied at render time.

**Edge Cases:**

- Wide terminals (COLUMNS > 130): column alignment is preserved; line wrapping is not
  applied to values.
- Entries with absent optional fields (e.g., `sdDescription`) are omitted entirely
  rather than rendered as empty or null.
- `OdStackDefinition` carries a `show_times` flag; when `False`, creation/update
  timestamps are suppressed from the definition section.

**Error Scenarios:**

- If the spinner is active when an output section is emitted, the spinner line is cleared
  via `\r\ESC[K` before rendering the section, then the spinner is restarted after.

**Complexity Notes:**

- The 25-character label padding is computed per-section; some sections use narrower
  effective column widths for sub-tables (e.g., stack event columns).
- Interactive and plain modes share the same rendering code path; plain mode sets ANSI
  disabled which causes all color/bold calls to be no-ops. Plain mode also disables
  spinners.

---

### US-06-002: Consume JSON output for automation

**As a** CI Pipeline, **I want to** receive all iidy output as structured JSON Lines,
**so that** I can parse deployment results, stack events, errors, and summaries
programmatically without screen-scraping ANSI text.

**Acceptance Criteria:**

- `--output-mode json` activates the `JsonRenderer` for all `OutputData` values.
- Each value is emitted as a single JSON object on its own line (JSONL / NDJSON format).
  No trailing comma, no surrounding array.
- Every emitted JSON object has the envelope structure:
  `{"type": "<type_name>", "timestamp": "<ISO8601>", "data": {<payload>}}`.
- Type names use `snake_case` and map from `OutputData` constructors. Of the 27
  constructors, 25 emit a JSON envelope with the following type names:
  `command_metadata`, `stack_definition`, `stack_events`, `stack_contents`,
  `status_update`, `command_result`, `final_command_summary`, `stack_list`,
  `changeset_result`, `stack_drift`, `error`, `token_info`, `new_stack_events`,
  `operation_complete`, `inactivity_timeout`, `confirmation_prompt`,
  `stack_change_details`, `stack_absent_info`, `cost_estimate`,
  `approval_request_result`, `template_validation`, `approval_status`,
  `template_diff`, `approval_result`, `raw_output`.
  Two constructors have special JSON behavior:
  - `OdPollingStarted`: suppressed (no output emitted in JSON mode).
  - `OdStackTemplate`: outputs raw template body to stdout (not JSON-wrapped).
  Note: `OdTokenInfo` emits a JSON envelope with type `token_info` (it is suppressed
  in interactive mode but not in JSON mode).
  Note: `OdRawOutput` emits a JSON envelope with type `raw_output` and a `data` field
  containing the raw text.
- All field names within `data` are `snake_case`.
- `OdStackList` with `sldQueryMode = True`: emits a raw JSON array of stack objects
  without the envelope wrapper (for pipeline composition with `jq`).
- `OdPollingStarted`: no output in JSON mode (suppressed).
- `OdStackTemplate`: stderr lines are written to stderr, template body is written to
  stdout as plain text (not JSON-wrapped), matching the get-stack-template command's
  contract.
- ANSI escape codes are never embedded in JSON field values.
- Timestamps within `data` payloads are serialized as ISO 8601 strings.
- The JSON output is stable: same `OutputData` value always produces the same JSON
  string.

**Logic Flow:**

1. The output dispatcher detects the JSON mode flag and routes to the JSON renderer.
2. The JSON renderer pattern-matches on the `OutputData` variant.
3. For standard variants: builds the type/timestamp/data envelope and serializes to JSONL.
4. For special cases (`OdStackList` query mode, `OdStackTemplate`, `OdPollingStarted`):
   applies the exception logic described above.

**Edge Cases:**

- `--color always` combined with `--output-mode json`: color is not applied (JSON mode
  forces `colorsEnabled = False` regardless of `--color` flag).
- Empty lists (e.g., zero stack events): serialized as `[]`, not omitted.
- `Nothing` / `Maybe` fields: serialized as `null` in JSON.
- Large templates (> 51,200 bytes): `OdStackTemplate.stTemplateBody` is emitted in full
  without truncation.

**Error Scenarios:**

- `OdError` in JSON mode is emitted as a JSON object to stdout (not stderr), maintaining
  JSONL stream integrity. The receiver must inspect the `type: "error"` field to detect
  errors.

**Complexity Notes:**

- `OdStackList` query-mode raw array is a deliberate design choice for shell pipeline
  interoperability: `iidy list-stacks --query '...' --output-mode json | jq '.[].StackName'`
  works without an extra `.data.stacks` unwrap step.

---

### US-06-003: Use plain output for CI/CD logs

**As a** CI Pipeline, **I want to** receive plain-text output without ANSI escape codes
or spinner animations, **so that** build logs are readable in log aggregators and do not
contain control characters.

**Acceptance Criteria:**

- `--output-mode plain` forces plain output mode regardless of TTY status.
- When stdout is not a TTY and `--output-mode` is absent, plain mode is selected
  automatically (`OutputInteractive` requires `tcIsTty = True`).
- Plain mode uses the same renderer as interactive mode with ANSI disabled and spinners
  disabled.
- All section headings, labels, and values are emitted as plain ASCII text without any
  `\ESC[...m` sequences.
- All 27 `OutputData` variants that produce output in interactive mode produce equivalent
  content in plain mode (same fields, same label text, same structure) with no ANSI codes.
- Spinner animation is fully suppressed: no braille characters, no `\r`, no
  `\ESC[K` line erasure.
- Timestamps are formatted identically to interactive mode (`%a %b %d %Y %H:%M:%S`).
- `OdConfirmationPrompt` in plain mode (or when not TTY/ANSI disabled): prints
  "CONFIRMATION REQUIRED: <message>" followed by "Use --yes flag to proceed automatically
  in non-interactive mode". Stdin is not read; the calling code must use `--yes` to
  suppress prompts in CI.
- `OdConfirmationPrompt` in interactive mode: prints "? <message> (y/N) " with the
  message in bold error color. Stdin reading is handled by the calling code, not the
  renderer.

**Logic Flow:**

1. The output dispatcher resolves mode to plain (explicit flag or non-TTY detection).
2. The renderer is created with ANSI disabled and spinners disabled.
3. All color and bold formatting calls return their input text unchanged.

**Edge Cases:**

- `--output-mode plain --color always`: `--color` is ignored when mode is plain; plain
  mode unconditionally disables ANSI.
- Confirmation prompts encountered in plain mode during non-interactive scripts must be
  handled by passing `--yes` at the command level, not by reading from stdin.

**Error Scenarios:**

- If stdout is redirected to a file while `--output-mode interactive` is explicitly
  forced: output is written with ANSI codes (user's explicit choice honored even when
  non-TTY).

**Complexity Notes:**

- Plain and interactive mode share a single renderer with a boolean flag controlling ANSI
  emission. This avoids duplicate formatting logic for layout, alignment, and section
  structure.

---

### US-06-004: Configure color and theme

**As a** Developer, **I want to** control the color palette and ANSI color behavior
through CLI flags and environment variables, **so that** I can match my terminal theme
and satisfy `NO_COLOR` compliance requirements.

**Acceptance Criteria:**

- `--color <WHEN>` accepts `auto`, `always`, `never`. Default: `auto`.
  - `always`: ANSI colors enabled regardless of TTY or env vars.
  - `never`: ANSI colors disabled regardless of TTY or env vars.
  - `auto`: enables colors when `tcHasColor = True` (TTY + no `NO_COLOR`).
- `--theme <THEME>` accepts `auto`, `dark`, `light`, `high-contrast`. Default: `auto`.
  - `auto`: resolves to `darkTheme` (same as `dark`).
  - `dark`: `darkTheme` — magenta primary, standard red/green/yellow, RGB grays.
  - `light`: `lightTheme` — dark red primary (RGB 163,21,21), crimson error
    (RGB 220,20,60), goldenrod `envDevelopment` (RGB 218,165,32).
  - `high-contrast`: `highContrastTheme` — all bright ANSI colors for accessibility
    (BrightWhite, BrightCyan, BrightGreen, BrightRed, BrightYellow, BrightBlue,
    BrightMagenta, BrightBlack).
- Priority for color: `--color always/never` > `NO_COLOR` / `FORCE_COLOR` env vars >
  TTY detection.
  - `NO_COLOR` (set to any value): forces `hasColor = False`, overrides `--color auto`.
  - `FORCE_COLOR` (set, no `NO_COLOR`): forces `hasColor = True`.
- The dark and light themes unconditionally emit RGB truecolor escape sequences
  (e.g., `\ESC[38;2;R;G;Bm`). High-contrast and no-color themes use only standard ANSI
  codes. No truecolor capability detection is performed — following the Rust `IidyTheme`
  system, which also emits RGB unconditionally. Terminals that do not support truecolor
  will approximate these colors.
- When colors are disabled, all theme color fields are set to the default (no-color);
  all color and bold formatting functions return their input text unchanged.

**Logic Flow:**

1. Terminal capabilities are detected by reading `NO_COLOR`, `FORCE_COLOR`, `COLUMNS`
   from the environment and checking whether stdout is a TTY.
2. The output dispatcher resolves whether colors are enabled from the `--color` flag and
   output mode.
3. The active theme is selected based on the colors-enabled flag and the `--theme` flag.
4. The resolved theme is passed into the renderer at construction time.

**Edge Cases:**

- `--output-mode json` forces `colorsEnabled = False` even with `--color always`.
- `--output-mode plain` forces `colorsEnabled = False` even with `--color always`.
- Only `--output-mode interactive` respects the `--color` flag.

**Error Scenarios:**

- Invalid `--theme` value: exit 1 with `error: Invalid value '<val>' for '--theme <THEME>'`
  (handled by CLI parser, not the output system).

**Complexity Notes:**

- Theme records are pure data; theme switching takes effect per-render call and does not
  require re-initializing the renderer.

---

### US-06-005: View real-time spinner during polling

**As a** Developer, **I want to** see an animated spinner with elapsed time while iidy is
polling for stack completion, **so that** I know the command is still running and how long
it has been since the last event.

**Acceptance Criteria:**

- Spinners are enabled only in interactive mode (`ioEnableSpinners = True`).
- The spinner uses the `SpinnerDots12` style: 12 braille frames
  (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⠋⠙`) at 100ms per frame.
- Spinner color: cyan bold (`AnsiBrightCyan` + bold ANSI sequence).
- Before any polling operation begins, `OdPollingStarted` is emitted with a message text.
  The interactive renderer starts the spinner with that message.
- The spinner message is updated every 1 second with:
  `X seconds elapsed total. Y since last event.`
  where X and Y are integer seconds.
- When a new `OdNewStackEvents` batch arrives: the spinner is stopped, the events are
  rendered, then the spinner is restarted.
- When `OdOperationComplete` or `OdInactivityTimeout` arrives: the spinner is stopped
  and cleared before rendering the completion section.
- Spinner cleanup uses `\r\ESC[K` (carriage return + erase-to-end-of-line) to avoid
  leaving braille artifacts in the terminal.
- The spinner writes to stdout (same handle as normal output); clearing must happen
  before any other output on that line.

**Logic Flow:**

1. `OdPollingStarted` received: start the spinner background tick thread (100ms interval)
   with the initial message.
2. Tick thread renders a new frame every 100ms; a separate 1-second timer updates the
   elapsed-time message.
3. `OdNewStackEvents` received: stop the spinner, render events, restart the spinner.
4. `OdOperationComplete` or `OdInactivityTimeout`: stop the spinner, render the final
   section.

**Edge Cases:**

- Multiple consecutive `OdPollingStarted` without intervening `OdOperationComplete`: the
  second start restarts the spinner (stop + start) to reset elapsed time.
- Spinner in plain mode: `OdPollingStarted` produces no output.
- Spinner in JSON mode: suppressed entirely.
- If the terminal does not support ANSI: color codes are suppressed but the braille
  frame character and message text are still emitted (spinner is functional but
  monochrome).

**Error Scenarios:**

- If the tick thread throws an exception: it is caught and the spinner is silently
  deactivated to prevent crashing the main output loop.

**Complexity Notes:**

The spinner subsystem uses two concurrent background threads coordinated via shared
mutable state:

```
Spinner Object (IORef-based):
    spFrameRef   -- current frame index (0..11)
    spMessage    -- current message text
    spActive     -- whether spinner is running
    spHandle     -- output handle (stdout)

Thread 1: Tick Thread (100ms interval)
    loop:
        frame = spinnerTick(spinner)      -- advance frame, set active=True
        render: "\r" + cyanBold + frame + reset + " " + message
        sleep 100ms

Thread 2: Timing Thread (1s interval)
    loop:
        sleep 1s
        read (startTime, lastEventTime) from shared TVar
        elapsed = now - startTime
        sinceLast = now - lastEventTime
        spinnerSetMessage(spinner, "<elapsed>s elapsed total. <sinceLast>s since last event.")

Stop Sequence:
    if spinner.active:
        emit "\r\ESC[K"   -- clear spinner line
        set active=False, reset frameRef=0
    kill tick thread
    kill timing thread

Event Arrival (OdNewStackEvents):
    preserve timing state (startTime, lastEventTime) from TVar
    stopSpinner
    render events
    startSpinner with fresh tick/timing threads
    restore preserved timing state into TVar
    update lastEventTime to latest event timestamp
```

- The active flag coordinates between the tick thread and the main thread. The spinner
  clear operation checks the active flag before emitting `\r\ESC[K` to avoid double-clear.
- Elapsed time and last-event time are tracked in renderer state via STM TVar, not in the
  spinner object itself. This separation allows timing to be preserved across
  stop/restart cycles when new events arrive.

---

### US-06-006: View stack events with duration and status

**As a** Developer, **I want to** see CloudFormation stack events with semantic status
coloring and per-event duration, **so that** I can quickly identify which resources are
failing or taking unexpectedly long.

**Acceptance Criteria:**

- `OdStackEvents` (historical events from describe-stack) and `OdNewStackEvents` (live
  events during polling) both render using the same per-event format.
- Each event row contains: timestamp, logical resource ID (in `thResourceId` color),
  resource type, resource status (colored via `colorizeResourceStatus`), and optionally
  a status reason.
- `StackEventWithTiming.sewDurationSeconds`: when present and `>= 1`, appended to the
  status as `(Xs)` in muted color. Duration `0` is not shown; the minimum displayed
  duration is 1 second.
- Event durations for past events (in `OdStackEvents`) are computed by
  `calculateEventDurations` which calculates the time between consecutive events of the
  same logical resource ID.
- Live events (in `OdNewStackEvents`) receive durations computed against the current
  wall-clock time via `convertEventWithDuration`.
- `StackEventsDisplay.sedTruncated`: when present, a muted line is appended after the
  event list: `Showing <shown> of <total> events`. Truncation occurs when
  `sedMaxEvents` is set and the event count exceeds it.
- `OdStackEvents` is rendered as a section with heading from `sedTitle`.
- `OdNewStackEvents` is emitted inline during polling (no section heading); events are
  appended to the previous event table visually.

**Logic Flow:**

1. `OdStackEvents`: render section heading, iterate event rows, optionally render
   truncation line.
2. `OdNewStackEvents`: stop spinner, render event rows, restart spinner.
3. For each event: format timestamp in timestamp color, pad logical ID to column width,
   apply semantic status coloring.

**Edge Cases:**

- Events with no timestamp: timestamp column is blank.
- Events with no status reason: reason column is omitted.
- Very long logical resource IDs: the ID is not truncated; subsequent columns shift right.
- Empty event list: section heading is emitted but no event rows; no truncation line.

**Error Scenarios:**

- Duration calculation overflow (extremely long-running stack events): not expected in
  practice on 64-bit systems.

**Complexity Notes:**

- Historical event duration calculation pairs events by logical resource ID to determine
  when a resource transitioned from IN_PROGRESS to its terminal state.

---

### US-06-007: View command metadata and final summary

**As a** Developer or CI Pipeline, **I want to** see structured metadata at the start and
a clear success/failure summary at the end of every write operation, **so that** I have
a consistent audit trail of who ran what, in which account, and whether it succeeded.

**Acceptance Criteria:**

- `OdCommandMetadata` is emitted at the start of every write operation (create-stack,
  update-stack, create-or-update, delete-stack, exec-changeset, describe-stack-drift,
  estimate-cost, lint-template).
- The metadata section renders as a section heading "Command Metadata" with entries:
  - `Environment` -> `cmEnvironment` (colored by `colorByEnvironment`)
  - `Region` -> `cmRegion`
  - `Profile` -> `cmProfile` (omitted if `Nothing`)
  - `IAM Service Role` -> `cmIamServiceRole` (omitted if `Nothing`)
  - `Current IAM Principal` -> `cmCurrentIamPrincipal`
  - `Credential Source` -> `cmCredentialSource`
  - `Version` -> `cmVersion`
  - `CLI Arguments` -> key=value pairs from `cmCliArguments` showing only CLI flags
    (not stack-args.yaml defaults)
  - `Primary Token` -> `cmPrimaryToken` token info
  - `Derived Tokens` -> listed if `cmDerivedTokens` is non-empty (for assumed-role
    sessions)
- `OdFinalCommandSummary` is emitted at the end of every write operation.
- In interactive mode, `FinalCommandSummary` renders as a section entry under
  "Command Summary:" label:
  - `SummarySuccess`: green-background + black-foreground "Success" text with thumbs-up
    emoji.
  - `SummaryFailure`: red-background + white-foreground "Failure" text with table-flip
    emoticon, followed by "Fix and try again." on its own line.
- In JSON mode, `final_command_summary` has fields: `result` (`"success"` or
  `"failure"`), `elapsed_seconds` (integer).
- `OdCommandResult` renders a single-line result: success/failure indication +
  `crMessage` (if present) + elapsed time.

**Logic Flow:**

1. Command entry point emits `OdCommandMetadata` before AWS API calls.
2. The command metadata record is assembled from the CFN context, global options, and
   STS response.
3. After the terminal stack status is received, a final command summary is built with
   elapsed time and emitted as `OdFinalCommandSummary`.

**Edge Cases:**

- `cmCliArguments` must show only explicitly passed CLI flags, not defaults. If the user
  passed `--environment production`, it appears; if they relied on the default
  `development`, it does not.
- Commands that fail before reaching the polling stage (e.g., preprocessing error): still
  emit `OdCommandMetadata` but do not emit `OdFinalCommandSummary` (error is shown via
  `OdError` instead).

**Error Scenarios:**

- STS `GetCallerIdentity` failure: the command continues but `cmCurrentIamPrincipal`
  shows an error placeholder and `cmCredentialSource` shows `unknown`.

**Complexity Notes:**

- `cmPrimaryToken` and `cmDerivedTokens` carry token info records (UUID string + source).
  These are used to correlate CloudFormation events with iidy invocations via the
  `ClientRequestToken` field on stack events.

---

### US-06-008: View errors with structured context

**As a** Developer or CI Pipeline, **I want to** receive structured error output that
includes the error type, message, suggestions, and contextual details, **so that** I can
diagnose failures without manual log correlation.

**Acceptance Criteria:**

- `OdError` carries an `ErrorInfo` record with: `eiErrorType`, `eiMessage`,
  `eiTimestamp`, `eiSuggestions`, `eiErrorDetails`.
- In interactive mode, errors are rendered with:
  - Error type header in bold red (or `thError` color).
  - Message text below the header.
  - `eiSuggestions` listed as bullet points in `thInfo` color if non-empty.
  - `ErrorStackAbsent` detail variant renders the stack name, environment, region,
    account, and auth ARN as structured entries (same label/value layout as other
    sections) to provide full context for "stack not found" errors.
- In JSON mode, `OdError` is serialized with the standard envelope; `type: "error"`.
  `error_details` is a tagged union: `{"type": "generic", "message": ...}` or
  `{"type": "stack_absent", "stack_name": ..., "environment": ..., ...}`.
- `OdStackAbsentInfo` is a standalone `OutputData` variant (not inside `OdError`) used
  when a command exits cleanly after determining a stack is absent (e.g.,
  `delete-stack` with `--fail-if-absent` omitted). It renders as a section with stack
  name, environment, region, account, and auth ARN — identical fields to
  `ErrorStackAbsent` but without error styling.
- Error output goes to stderr in both interactive and plain modes. In JSON mode, errors
  go to stdout to maintain JSONL stream integrity.

**Logic Flow:**

1. The top-level error handler catches exceptions, constructs `ErrorInfo`, and emits
   `OdError`.
2. The interactive renderer checks the error detail variant; dispatches to generic or
   stack-absent sub-renderer.
3. The stack-absent sub-renderer emits a "Stack not found" section with STS context
   entries.

**Edge Cases:**

- Empty suggestions list: no bullet list is rendered; no blank line placeholder.
- Error during output rendering itself (e.g., broken pipe): caught at the top level;
  process exits 1 without further output.
- `OdError` in JSON mode written to stdout (not stderr): the receiver must filter by
  `type: "error"` rather than relying on stderr separation.

**Error Scenarios:**

- Multiple `OdError` values in a single command invocation: each is rendered independently.
  This can occur when a stack operation partially succeeds (events emitted) before a
  terminal failure.

**Complexity Notes:**

- The error detail variant distinguishes a generic error from a stack-absent error. This
  enables the interactive renderer to apply richer formatting (account/region context) for
  the common "stack not found" case without ad-hoc string matching.

---

### US-06-009: View stack list with filtering and lifecycle icons

**As a** Platform Engineer, **I want to** list all CloudFormation stacks in a region with
column selection, tag filtering, and environment-aware coloring, **so that** I can audit
a region's stack inventory quickly.

**Acceptance Criteria:**

- `OdStackList` renders the `StackListDisplay` record, which carries: `sldStacks` (list
  of `StackListEntry`), `sldShowTags`, `sldFiltersApplied`, `sldColumns`, `sldQueryMode`.
- Default columns: Name, Status, CreationTime (or as configured by `sldColumns`).
  Additional columns: Tags, StatusReason, TerminationProtection, Environment.
  Note: the interactive renderer uses a fixed column layout (timestamp, status, name,
  optional tags) regardless of `sldColumns`. Only the JSON renderer respects `sldColumns`
  for machine consumers.
- Stack name column: termination-protected stacks (`sleTerminationProtection = True`)
  are prefixed with 🔒. (Additional lifecycle icons ∞ and ♺ apply for specific deletion
  policies.)
- Stack status column: colored via `colorizeResourceStatus`.
- Environment column: when `sleEnvironmentType` is `Just env`, the value is colored via
  `colorByEnvironment`.
- Tag column: shown only when `sldShowTags = True`; rendered as `key=value` pairs
  separated by spaces.
- `sldFiltersApplied`: when non-empty, a muted header line is printed before the table:
  `Filters: <filter1>, <filter2>, ...`.
- `sldQueryMode = True`: in JSON mode, emits a raw JSON array instead of the standard
  JSONL envelope (for `jq` pipeline interoperability). In interactive mode, `queryMode`
  has no effect on rendering.
- Empty stack list: column headers are still printed; no row data follows.

**Logic Flow:**

1. `OdStackList` received: check `sldFiltersApplied`, emit filter header if needed.
2. Emit column header row with column names.
3. Iterate `sldStacks`, applying column selection and coloring per entry.
4. In JSON mode, check `sldQueryMode`; if true, serialize as raw array.

**Edge Cases:**

- `sleCreationTime = Nothing`: creation time column is blank for that row.
- Stacks with many tags: tag column can be wide; no truncation is applied.
- `sldColumns = []`: falls back to default columns (Name, Status, CreationTime).

**Error Scenarios:**

- No stacks returned after filtering: exit 0, table header only, no error emitted.

**Complexity Notes:**

- Column width calculation for the tabular layout must account for Unicode characters
  in stack names (emoji, non-ASCII). The column widths are computed over the full
  `sldStacks` list before rendering any row to avoid mid-table realignment.

---

### US-06-010: Disable colors via NO_COLOR environment variable

**As a** CI Pipeline or accessibility-conscious user, **I want to** set `NO_COLOR` in
my environment to unconditionally suppress all ANSI escape codes from iidy output,
**so that** I get predictable plain text without modifying any iidy-specific configuration.

**Acceptance Criteria:**

- When `NO_COLOR` is set (to any value, including empty string), `detectCapabilities`
  returns `tcHasColor = False` and `tcIsTty` is still accurately reported.
- `NO_COLOR` takes precedence over `FORCE_COLOR`. If both are set, colors are disabled.
- `NO_COLOR` does not affect the output mode selection (interactive vs. plain vs. json).
  A TTY session with `NO_COLOR` set still uses the interactive renderer but with all
  ANSI sequences stripped.
- With `tcHasColor = False` and `--color auto` (the default), `colorsEnabled = False`,
  which causes `resolveTheme False _ = noColorTheme`.
- The no-color theme sets all 14 color fields to the default terminal color and marks
  colors as disabled.
- The `colorize`, `colorizeBold`, `colorizeOnBg`, and `bold` functions all guard on
  `thColorsEnabled`; when `False`, they return the input text unmodified (zero escape
  codes emitted).
- `colorizeResourceStatus` and `colorByEnvironment` also route through `colorize` and
  are therefore also no-ops when `thColorsEnabled = False`.
- The spinner is still animated (braille characters, `\r` line overwrite) when
  `NO_COLOR` is set, since `ioEnableSpinners` is independent of color enablement.
  Only the cyan bold color code around the spinner frame character is suppressed.
- `--color never` produces identical behavior to `NO_COLOR` from the perspective of ANSI
  output, but is applied at the `mkOutputDispatch` level rather than the
  `detectCapabilities` level.

**Logic Flow:**

1. Terminal capabilities are detected; `NO_COLOR` env var sets `hasColor = False`.
2. The output dispatcher's `ColorAuto` path: `hasColor = False` means `colorsEnabled = False`.
3. With colors disabled, the no-color theme is selected (all theme fields set to default,
   no ANSI codes).
4. The renderer is constructed with ANSI disabled.
5. All color formatting calls return plain text.

**Edge Cases:**

- `--color always` combined with `NO_COLOR`: the explicit CLI flag overrides the
  environment convention. Users who need strict `NO_COLOR` compliance should not pass
  `--color always`.
- `NO_COLOR` with `--output-mode json`: JSON mode already forces colors disabled;
  `NO_COLOR` is redundant but harmless.

**Error Scenarios:**

- `NO_COLOR` set to a non-empty string (e.g., `NO_COLOR=1`): identical behavior to
  `NO_COLOR=` (empty). The spec says "any value".

**Complexity Notes:**

- `NO_COLOR` compliance is an ecosystem-level convention (https://no-color.org/). It is
  implemented at the terminal detection layer rather than at the CLI flag layer: the
  environment variable is checked once at startup and its result flows through the entire
  output pipeline without needing per-call checks.

---

## Testing Requirements

- All 27 `OutputData` event types are covered by renderer tests in both interactive and
  JSON modes.
- `OdTokenInfo` and `OdPollingStarted` produce no stdout output in interactive and plain
  modes. Verified by capturing stdout in tests and asserting empty output.
- `OdStackList` with `sldQueryMode = True` in JSON mode emits a raw JSON array (no
  envelope). Verified by parsing the output and checking the top-level JSON type is an
  array.
- `OdStackTemplate` in JSON mode writes stderr lines to stderr and body to stdout.
  Verified with separate stdout/stderr capture.
- All four themes produce distinct color sequences for error, success, and warning in
  interactive mode.
- The no-color theme produces zero `\ESC[` sequences for any `OutputData` value. Verified
  by asserting no ANSI escape codes appear in the output over all 27 event types.
- `NO_COLOR` env var: test that terminal capability detection with `NO_COLOR` set returns
  `hasColor = False`.
- `FORCE_COLOR` env var: test that detection returns `hasColor = True` when `FORCE_COLOR`
  is set and `NO_COLOR` is absent.
- `IIDY_THEME` env var: test all four accepted values (`light`, `high-contrast`,
  `highcontrast`, `dark`) and an unknown value (defaults to auto/dark).
- Theme resolution with colors disabled returns the no-color theme for all four theme
  values.
- Spinner cleanup emits `\r\ESC[K` only when the spinner is active; emits nothing when
  inactive.
- Resource status coloring tests: verify each status keyword substring maps to the
  expected color code under the dark theme.
- Environment coloring tests: verify `production`, `integration`, `development` map to
  correct theme colors; verify unknown env name returns plain text.
- Interactive renderer alignment tests: entry labels are left-padded to exactly 25
  characters; values begin at column 26.
- Timestamp format test: timestamps are rendered with `%a %b %d %Y %H:%M:%S`
  (locale-independent, English day/month names).
- JSON stability test: same `OutputData` value serialized twice produces identical JSON
  strings.
- Final command summary: `SummarySuccess` output contains "Success" in green;
  `SummaryFailure` output contains "Failure" in red (verified by ANSI code inspection).

---

## Cross-References

- `docs/requirements/01-cli-interface.md` — US-01-015 (machine-readable output mode),
  US-01-016 (environment-based configuration, `NO_COLOR`/`FORCE_COLOR`/`IIDY_THEME`)
- PRD-05: CloudFormation Operations — all `OutputData` event types emitted by operations
- PRD-07: Error Handling — error formatting pipeline (`OdError`, `ErrorInfo`, etc.)
- `DIVERGENCES.md` — error color detection uses stderr TTY vs stdout TTY (Rust)
- Rust oracle: `~/src/iidy/target/debug/iidy` — interactive rendering reference for
  section layout, column widths, timestamp format, and status color mapping
