# Output Architecture

The output system is a three-layer pipeline: command handlers emit typed
`OutputData` values, `OutputDispatch` routes them to the active renderer, and
renderers format the data for the target medium (terminal or JSON).

No command handler should ever call `putStrLn` or `hPutStrLn` directly.  All
visible output flows through `renderOutput`.

## Layer 1: OutputData Enum

`src/Iidy/Output/Types.hs` defines the sum type that represents
every piece of output the system can produce.  Each variant wraps a strict,
self-contained record -- renderers never need to reach back into command state.

| Variant | Payload | Purpose |
|---|---|---|
| `OdCommandMetadata` | `CommandMetadata` | CLI context: region, profile, IAM principal, tokens, version |
| `OdStackDefinition` | `StackDefinition, Bool` | Stack name/status/tags/params/ARN; `Bool` controls time display |
| `OdStackEvents` | `StackEventsDisplay` | Paginated historical events with optional truncation info |
| `OdStackContents` | `StackContents` | Resources, outputs, exports, current status, pending changesets |
| `OdStatusUpdate` | `StatusUpdate` | Single timestamped message at Info/Warning/Error/Success level |
| `OdCommandResult` | `CommandResult` | Final operation result with exit code and elapsed time |
| `OdFinalCommandSummary` | `FinalCommandSummary` | Overall summary line (Success/Failure + elapsed seconds) |
| `OdStackList` | `StackListDisplay` | Paginated stack listing with configurable columns |
| `OdChangeSetResult` | `ChangeSetCreationResult` | Changeset creation outcome, console URL, next steps |
| `OdStackDrift` | `StackDrift` | Drift detection results with per-resource property diffs |
| `OdError` | `ErrorInfo` | Structured error with type, message, suggestions, details |
| `OdTokenInfo` | `TokenInfo` | STS credential info (silent in interactive mode) |
| `OdNewStackEvents` | `[StackEventWithTiming]` | Live polling events streamed during create/update/delete |
| `OdOperationComplete` | `OperationCompleteInfo` | Polling completion marker with elapsed time |
| `OdInactivityTimeout` | `InactivityTimeoutInfo` | Timeout fired during polling (no new events) |
| `OdConfirmationPrompt` | `ConfirmationRequest` | Interactive yes/no prompt (auto-declined in JSON mode) |
| `OdStackChangeDetails` | `StackChangeDetails` | Change type (Create/Update/Delete) and stack name |
| `OdStackAbsentInfo` | `StackAbsentInfo` | Stack not found, includes STS context (account, region, ARN) |
| `OdCostEstimate` | `CostEstimate` | AWS pricing calculator URL |
| `OdStackTemplate` | `StackTemplate` | Template body (stdout) with optional stderr prefix lines |
| `OdApprovalRequestResult` | `ApprovalRequestResult` | Template approval initiation result |
| `OdTemplateValidation` | `TemplateValidation` | Validation errors/warnings |
| `OdApprovalStatus` | `ApprovalStatus` | Current approval state (pending, already approved) |
| `OdTemplateDiff` | `TemplateDiff` | Unified diff output between template versions |
| `OdApprovalResult` | `ApprovalResult` | Approval completion with cleanup status |
| `OdPollingStarted` | `Text` | Spinner message shown before polling begins |

All payload types derive `Show` and `Eq`.  They use strict fields (`!`) and
`Text` throughout -- no `String` anywhere in the output types.

## Layer 2: OutputDispatch

`src/Iidy/Output/Manager.hs` owns the dispatch layer.

```haskell
data OutputDispatch
  = DispatchInteractive !InteractiveRenderer
  | DispatchJson !JsonRenderer

mkOutputDispatch :: GlobalOpts -> IO OutputDispatch
renderOutput     :: OutputDispatch -> OutputData -> IO ()
```

`mkOutputDispatch` resolves the output mode through a priority chain:

1. Explicit `--output` flag (`Json | Plain | Interactive`)
2. TTY detection: if stdout is a terminal, `Interactive`; otherwise `Plain`

Color resolution follows a separate chain:

1. `--color` flag: `always` forces on, `never` forces off, `auto` falls through
2. In `auto` mode: enabled only for `Interactive` mode with `tcHasColor` true
3. `NO_COLOR` env var disables; `FORCE_COLOR` env var enables (checked by
   `detectCapabilities` in `src/Iidy/Output/Terminal.hs`)

Theme is selected by `--theme` flag or `IIDY_THEME` env var, then resolved
against the color-enabled flag via `resolveTheme`:

```haskell
resolveTheme :: Bool -> ColorTheme -> IidyTheme
-- colorsEnabled=False always produces noColorTheme
-- colorsEnabled=True maps ThemeAuto/ThemeDark -> darkTheme, etc.
```

`Plain` mode creates an `InteractiveRenderer` with ANSI and spinners disabled
(same formatting logic, no escape codes).  `Json` mode creates a `JsonRenderer`.

## Layer 3: Renderers

### InteractiveRenderer

**File:** `src/Iidy/Output/Renderers/Interactive.hs`

The largest output module.  Manages ANSI formatting, column alignment, spinner
lifecycle, and section-based output grouping.

```haskell
data InteractiveRenderer = InteractiveRenderer
  { irTheme              :: !IidyTheme
  , irOptions            :: !InteractiveOptions
  , irTerminalWidth      :: !Int
  , irHasRenderedContent :: !(IORef Bool)
  , irSpinner            :: !(IORef (Maybe Spinner))
  , irSpinnerThread      :: !(IORef (Maybe ThreadId))
  , irTimingState        :: !(IORef (Maybe (UTCTime, Maybe UTCTime)))
  , irTimingThread       :: !(IORef (Maybe ThreadId))
  }
```

The main dispatch function pattern-matches all variants:

```haskell
renderOutputData :: InteractiveRenderer -> OutputData -> IO ()
```

Before dispatching, it clears the active spinner for all variants except
`OdNewStackEvents` (manages its own spinner), `OdPollingStarted` (starts one),
and `OdTokenInfo` (no-op in interactive mode).

**Column alignment constants:**

| Constant | Value | Purpose |
|---|---|---|
| `column2Start` | 25 | Left margin for value column in section entries |
| `minStatusPadding` | 17 | Minimum padding for status text in event rows |
| `maxPadding` | 60 | Upper bound on padding calculations |
| `resourceTypePadding` | 40 | Fixed width for resource type column |
| `defaultScreenWidth` | 130 | Fallback when `$COLUMNS` is unset and not a TTY |

**Key formatting functions:**

```haskell
formatSectionHeading :: InteractiveRenderer -> Text -> Text
-- Applies bold + sectionHeading color, ensures trailing colon

formatSectionEntry :: InteractiveRenderer -> Text -> Text -> Text
-- Two-column layout: label at col 1, value at column2Start

colorizeResourceStatus :: IidyTheme -> Text -> Text
-- IN_PROGRESS -> warning, COMPLETE -> success, FAILED -> error
```

### JsonRenderer

**File:** `src/Iidy/Output/Renderers/Json.hs`

Outputs JSON Lines (one JSON object per `OutputData` value).

```haskell
data JsonRenderer = JsonRenderer { jrOptions :: !JsonOptions }

renderOutputDataJson :: JsonRenderer -> OutputData -> IO ()
```

Each object has the envelope structure:

```json
{"type": "stack_definition", "timestamp": "2026-02-22T...", "data": {...}}
```

The `type` field is a snake_case string derived from the variant name.
Timestamps are ISO 8601.  Every payload type has a corresponding `*ToValue`
conversion function exported for testing.

Special cases:
- `OdStackList` in query mode outputs a raw JSON array (no envelope)
- `OdStackTemplate` writes stderr lines to stderr, template body to stdout
- `OdConfirmationPrompt` auto-declines with `"response": "declined_non_interactive"`
- `OdPollingStarted` and `OdTokenInfo` are no-ops

## Section Management

The interactive renderer organizes output into visual sections.  Each section
starts with a bold heading (`formatSectionHeading`) followed by indented
key-value entries (`formatSectionEntry` at `column2Start`).

Sections are emitted sequentially as `OutputData` values arrive.  There is no
out-of-order buffering -- unlike the Rust version which uses async task
scheduling, the Haskell version processes output synchronously in the IO monad.
Blank lines between sections are managed by `addContentSpacing`, which checks
`irHasRenderedContent` to avoid a leading blank line.

Typical output sequence for a write operation:

```
OdCommandMetadata   -> "Command Metadata:" section
OdStackDefinition   -> "Stack Details:" section
OdStackEvents       -> "Previous Stack Events:" section
OdPollingStarted    -> spinner begins
OdNewStackEvents    -> live event lines (spinner auto-clears per render)
OdOperationComplete -> spinner stops, blank line
OdStackContents     -> "Stack Resources:" / "Stack Outputs:" sections
OdFinalCommandSummary -> "Success" / "Failure" summary line
```

## Spinner Lifecycle

**File:** `src/Iidy/Output/Spinner.hs` (pure spinner state) and
`src/Iidy/Output/Renderers/Interactive.hs` (lifecycle management).

```haskell
startSpinner :: InteractiveRenderer -> Text -> IO ()
stopSpinner  :: InteractiveRenderer -> IO ()
```

`startSpinner` guards on two conditions: `ioEnableSpinners` must be true
(disabled for Plain mode) and stdout must be a TTY.  If both pass:

1. Calls `stopSpinner` to clean up any existing spinner
2. Creates a `Spinner` with `SpinnerDots12` style (braille animation)
3. Forks a background tick thread via `forkIO` that calls `spinnerRender`
   every 100ms, writing `\r` + colored frame + message
4. Starts a timing task (see below)

`stopSpinner` reverses the process:

1. Kills the timing thread
2. Kills the tick thread via `killThread`
3. Clears the terminal line with `\r\ESC[K`

The tick thread runs in an infinite loop. `killThread` raises an async
exception to terminate it -- this is the standard Haskell pattern for
cancelling background IO threads.

### Timing Display

A second background thread updates the spinner message every 1 second:

```haskell
formatTimingText :: Int -> Maybe Int -> Text
-- "X seconds elapsed total."
-- "X seconds elapsed total. Y since last event."
```

The timing state is stored in `irTimingState :: IORef (Maybe (UTCTime, Maybe UTCTime))`,
where the tuple holds `(operation_start_time, last_event_time)`.  When
`OdNewStackEvents` arrives, the last-event time is updated, and subsequent
spinner ticks show both the total and since-last-event durations.

## Color and Theming

**Files:** `src/Iidy/Output/Color.hs`, `src/Iidy/Output/Theme.hs`

```haskell
data IidyTheme = IidyTheme
  { thColorsEnabled   :: !Bool
  , thTimestamp       :: !DynColor
  , thResourceId      :: !DynColor
  , thSectionHeading  :: !DynColor
  , thMuted           :: !DynColor
  , thPrimary         :: !DynColor
  , thSuccess         :: !DynColor
  , thError           :: !DynColor
  , thWarning         :: !DynColor
  , thInfo            :: !DynColor
  , thSkipped         :: !DynColor
  , thEnvProduction   :: !DynColor
  , thEnvIntegration  :: !DynColor
  , thEnvDevelopment  :: !DynColor
  }
```

Four theme presets: `darkTheme` (default, matches original iidy-js colors with
truecolor RGB values), `lightTheme`, `highContrastTheme`, and `noColorTheme`
(all `AnsiDefault`).

`DynColor` supports both 4-bit ANSI colors and 24-bit RGB.  Color application
functions (`colorize`, `colorizeBold`, `colorizeOnBg`) check `thColorsEnabled`
and emit raw text when disabled.  No ANSI codes ever reach the output in
Plain or JSON mode.

Semantic helpers map CloudFormation concepts to theme colors:

```haskell
colorizeResourceStatus :: IidyTheme -> Text -> Text
-- Matches on IN_PROGRESS/COMPLETE/FAILED/DELETE_SKIPPED substrings

colorByEnvironment :: IidyTheme -> Text -> Text -> Text
-- Maps "production"/"integration"/"development" to theme colors
```

## Command Handler Rules

Every command handler that performs AWS operations MUST follow this protocol:

1. **Emit `OdCommandMetadata` first** -- region, profile, IAM principal, tokens
2. **Use `renderOutput dispatch` for all output** -- never bypass the pipeline
3. **Emit `OdFinalCommandSummary` last** -- shows Success/Failure with elapsed time

For write operations (create-stack, update-stack, delete-stack, create-or-update):

```
renderOutput dispatch (OdCommandMetadata meta)
renderOutput dispatch (OdStackDefinition def True)
renderOutput dispatch (OdStackEvents previousEvents)
renderOutput dispatch (OdPollingStarted "Waiting for stack operation...")
-- polling loop emits OdNewStackEvents as they arrive
renderOutput dispatch (OdOperationComplete info)
renderOutput dispatch (OdStackContents contents)
renderOutput dispatch (OdFinalCommandSummary summary)
```

Read-only commands (describe-stack, list-stacks, get-template) skip the polling
phase but still bracket with metadata and summary.

## Terminal Capabilities

**File:** `src/Iidy/Output/Terminal.hs`

```haskell
data TerminalCapabilities = TerminalCapabilities
  { tcHasColor     :: !Bool       -- NO_COLOR / FORCE_COLOR / isatty
  , tcHasTrueColor :: !Bool       -- COLORTERM=truecolor|24bit
  , tcWidth        :: !(Maybe Int) -- COLUMNS env var or 80 if TTY
  , tcIsTty        :: !Bool       -- hIsTerminalDevice stdout
  }
```

Detection runs once at dispatch creation time.  The capabilities record is
immutable after that -- no mid-session re-detection.

## Key Files

| File | Purpose |
|---|---|
| `src/Iidy/Output/Types.hs` | All `OutputData` variants and their payload types |
| `src/Iidy/Output/Manager.hs` | `OutputDispatch`, `mkOutputDispatch`, `renderOutput` |
| `src/Iidy/Output/Renderer.hs` | `OutputMode` enum and `OutputRenderer` typeclass |
| `src/Iidy/Output/Renderers/Interactive.hs` | ANSI terminal renderer with spinners |
| `src/Iidy/Output/Renderers/Json.hs` | JSON Lines renderer with `*ToValue` converters |
| `src/Iidy/Output/Spinner.hs` | Spinner frame animation and terminal line management |
| `src/Iidy/Output/Color.hs` | `DynColor`, `IidyTheme`, colorization functions |
| `src/Iidy/Output/Theme.hs` | `ColorTheme` selection and `resolveTheme` |
| `src/Iidy/Output/Terminal.hs` | TTY and color capability detection |
