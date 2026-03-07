# PRD: Cross-Cutting Concerns

## Overview

This document specifies requirements for iidy cross-cutting concerns: behaviors
that are not specific to a single command but affect the entire system. These include YAML version
detection, color/environment variable handling, NTP time synchronization, idempotency tokens,
signal handling, terminal capability detection, and confirmation prompts. All requirements here
describe behavior that must hold uniformly across every command.

---

## Technical Context

Several of these behaviors diverge from the Rust reference implementation in documented ways (see
`DIVERGENCES.md`). This PRD captures the normative specification.

Key concerns:

- **YAML version detection** — per-document detection of YAML 1.1 vs 1.2 semantics.
- **Terminal capability detection** — color, true-color, and width detection at startup.
- **Color control** — environment variable and CLI flag override chain.
- **NTP time synchronization** — reliable timestamps for write operations.
- **Idempotency token generation** — deterministic derived tokens for retryable AWS calls.
- **Signal handling** — SIGINT → exit 130 without runtime backtrace noise.
- **Confirmation prompts** — consistent format and behavior across all confirmation-gated commands.

Personas addressed:

- **Developer**: authors YAML templates, runs iidy locally, cares about readable output and
  correct YAML interpretation.
- **Platform Engineer**: integrates iidy into deployment pipelines, cares about color-safe output,
  reproducible tokens, and reliable write-op timestamps.
- **CI Pipeline**: non-interactive process, no TTY, must receive correct exit codes and parseable
  output.
- **Reviewer**: reads CloudFormation change output and event logs, cares about formatting
  consistency.

---

## User Stories

---

### US-12-001: Auto-Detect YAML Version

**As a** Developer or Platform Engineer,
**I want** iidy to automatically determine whether my YAML template uses YAML 1.1 or 1.2
semantics,
**so that** values like `yes`, `no`, `on`, `off` are interpreted correctly for the document type
without requiring me to annotate every file.

#### Acceptance Criteria

1. If the first 5 lines of the input contain `%YAML 1.1`, the file is classified as `ExplicitV11`
   and YAML 1.1 compatibility mode is enabled.
2. If the first 5 lines contain `%YAML 1.2`, the file is classified as `ExplicitV12` and YAML 1.2
   strict mode is used.
3. If no `%YAML` directive is present and at least 2 of the recognized CFN top-level keys
   (`AWSTemplateFormatVersion`, `Transform:`, `Resources:`, `Parameters:`, `Outputs:`,
   `Conditions:`, `Mappings:`, `Metadata:`) appear in the first 50 lines, the file is classified
   as `DetectedCloudFormation` and YAML 1.1 compatibility mode is enabled.
4. If no CFN heuristic matches but `apiVersion:` and `kind:` and at least one of the known
   Kubernetes API groups (`apps/v1`, `v1`, `batch/v1`, `networking.k8s.io/v1`,
   `rbac.authorization.k8s.io/v1`, `policy/v1`) appear in the first 20 lines, the file is
   classified as `DetectedKubernetes` and YAML 1.2 strict mode is used.
5. If no heuristic matches, the file is classified as `UnknownSpec` and YAML 1.2 strict mode is
   used (safest default).
6. The `--yaml-spec` CLI flag accepts `auto`, `1.1`, and `1.2`. `auto` defers to detection;
   `1.1` forces `ExplicitV11`; `1.2` forces `ExplicitV12`.
7. In YAML 1.1 compatibility mode, the 18 boolean variants (`yes`, `no`, `on`, `off`, `true`,
   `false` in all-lowercase, all-uppercase, and title-case) are converted to boolean scalars
   before further processing.
8. Detection is applied per-document, not per-invocation. Included sub-files are evaluated
   independently.

#### Logic Flow

```
input text
  └─ take first 5 lines
       └─ detectDirective: scan for %YAML 1.1 / %YAML 1.2 prefix
            ├─ found → ExplicitV11 or ExplicitV12
            └─ not found → detectByContent on all lines
                 ├─ isCloudFormation: count CFN key matches in first 50 lines ≥ 2
                 │    → DetectedCloudFormation
                 ├─ isKubernetes: apiVersion + kind + known API in first 20 lines
                 │    → DetectedKubernetes
                 └─ otherwise → UnknownSpec

shouldUseYaml11Compatibility:
  ExplicitV11, DetectedCloudFormation → True
  ExplicitV12, DetectedKubernetes, UnknownSpec → False
```

#### Edge Cases

- File is empty: no directive found, no content lines → `UnknownSpec` → YAML 1.2.
- File has `%YAML 1.1` on line 6 (past the 5-line window): treated as content, not a directive;
  heuristic detection applies.
- CFN file that also contains `apiVersion:` and `kind:` (unlikely but possible): CFN check runs
  first and wins, returning `DetectedCloudFormation`.
- `%YAML` directive present with unrecognized version (e.g., `%YAML 2.0`): not matched by either
  check; falls through to heuristic detection.
- Key counting is substring-based (`isInfixOf`), not key-position-aware. A comment line
  containing `Resources:` will be counted.

#### Error Scenarios

- Malformed `%YAML` directive line (e.g., `%YAML1.1` without space): not matched; heuristic
  detection applies without error.
- `--yaml-spec` given an unrecognized value: CLI argument parsing rejects it with a usage error
  before reaching detection logic.

#### Complexity Notes

- Detection is pure and O(n) in input length. No IO.
- The threshold of 2 CFN key matches was chosen to avoid false positives from files that
  coincidentally use one CFN-like key name.
- Kubernetes detection requires all three conditions (apiVersion + kind + known API) to reduce
  false positives on non-K8s documents that happen to use those field names.

---

### US-12-002: Control Output Colors via Environment

**As a** CI Pipeline or Platform Engineer,
**I want** iidy to respect standard color-control environment variables,
**so that** I can reliably strip ANSI codes from output in automated contexts and force color in
environments where TTY detection fails.

#### Acceptance Criteria

1. Color is disabled for all output when `NO_COLOR` is set to any value (including empty string),
   following the no-color.org specification.
2. Color is forced on for all output when `FORCE_COLOR` is set to any value and `NO_COLOR` is
   not set.
3. If neither `NO_COLOR` nor `FORCE_COLOR` is set, color is enabled only when stdout is a TTY.
4. The `--color` CLI flag (`always`, `auto`, `never`) overrides environment variable detection:
   `always` → force color; `never` → disable color; `auto` → use environment/TTY detection.
5. Error-path color is determined by checking whether stderr is a TTY, independently of stdout.
   This diverges from the Rust implementation, which checks stdout for error colors.
6. Color state is determined once at startup and passed through the output dispatch layer; it is
   not re-evaluated per output event.
7. No truecolor capability detection is performed. The dark and light themes unconditionally emit
   RGB truecolor escape sequences when colors are enabled. This follows the Rust `IidyTheme`
   system. `COLORTERM` is not read.

#### Logic Flow

```
color resolution (stdout path):
  --color always    → hasColor = True
  --color never     → hasColor = False
  --color auto / default:
    NO_COLOR set    → hasColor = False  (highest precedence after explicit flag)
    FORCE_COLOR set → hasColor = True
    otherwise       → hasColor = hIsTerminalDevice stdout

error color resolution:
  same precedence chain as above, but terminal check uses stderr handle
```

#### Edge Cases

- `NO_COLOR=""` (set but empty): colors disabled. Any set value disables colors.
- Both `NO_COLOR` and `FORCE_COLOR` set: `NO_COLOR` wins.
- `COLORTERM=Truecolor` (capital T): not matched; hasTrueColor = False. Comparison is
  case-sensitive.
- Running under a terminal multiplexer (tmux, screen) that sets `TERM=screen-256color` but not
  `COLORTERM`: true-color disabled; 8-color ANSI still active if TTY detected.
- Redirecting stdout to a file while stderr is a terminal: stdout has no color, error output
  retains color.

#### Error Scenarios

- `--color` given an unrecognized value: CLI argument parsing rejects it before runtime.
- `IIDY_THEME` set to an unrecognized theme: falls back to default theme with a warning.

#### Complexity Notes

- The divergence from Rust (stderr TTY check for errors) is intentional and tracked in
  `DIVERGENCES.md`. It produces more correct behavior when stdout is redirected.
- Terminal capabilities are detected once at startup and passed into the output dispatch.
  The detection is a single IO action.

---

### US-12-003: Synchronize Time via NTP for Write Operations

**As a** Platform Engineer or CI Pipeline,
**I want** iidy to use a reliable wall-clock time for write operations,
**so that** timestamps in CloudFormation event logs and command metadata are accurate even on
systems with clock skew.

#### Acceptance Criteria

1. Read-only operations (describe-stack, list-stacks, etc.) use the system clock
   (`SystemTimeProvider`).
2. Write operations (create-stack, update-stack, delete-stack, create-changeset,
   exec-changeset, create-or-update) use the reliable time provider, which queries NTP
   before falling back to the system clock.
3. NTP queries use the SNTP protocol (RFC 4330) against `pool.ntp.org:123`.
4. The SNTP request is a 48-byte UDP packet with LI=0, VN=4, Mode=3 (client).
5. NTP epoch offset is exactly 2,208,988,800 seconds (difference between 1900-01-01 and
   1970-01-01 UTC).
6. NTP query has a 2-second timeout with 2 total attempts (1 initial + 1 retry) before
   falling back to system time.
7. NTP failure is silent: the system clock is used without surfacing an error to the user.
8. Tests use a mock time provider with a fixed timestamp. No live NTP calls occur in the test suite.
9. The time provider is injected into command handlers via the command context; command
   handlers do not call system time directly.

#### Logic Flow

```
command dispatch:
  read op  → system clock directly
  write op → reliable time provider:
               attempt SNTP query to pool.ntp.org:123
                 success → NTP timestamp (converted from 1900 epoch to 1970 epoch)
                 timeout or error (up to 2 retries) → system clock fallback
test env  → mock time provider → returns fixed timestamp
```

#### Edge Cases

- Network unreachable: all NTP retries fail silently; system time used.
- NTP response arrives but packet is unparseable (wrong size, zero transmit timestamp):
  treated as failure; system time used. No plausibility check is performed on the
  returned timestamp.
- System clock is correct but NTP takes 1.9 seconds per attempt: up to ~4 seconds added to
  write-op startup time in the worst case.
- Monotonic clock drift mid-operation: not addressed. Time is sampled once per command
  invocation.

#### Error Scenarios

- DNS resolution of `pool.ntp.org` fails: treated as NTP failure; falls back to system time.
- UDP socket cannot be created (highly unusual): treated as NTP failure; falls back to system
  time.

#### Complexity Notes

- SNTP is implemented as a custom module rather than using an external NTP library, to avoid
  unnecessary dependencies.
- The distinction between read and write time providers ensures that expensive NTP queries
  are not incurred for cheap read operations.

---

### US-12-004: Use Idempotent Operations with Tokens

**As a** Platform Engineer or CI Pipeline,
**I want** iidy to generate deterministic idempotency tokens for AWS API calls,
**so that** retrying a failed write operation does not create duplicate CloudFormation stacks
or changesets.

#### Acceptance Criteria

1. Every write operation that accepts an idempotency token generates a UUID v4 automatically
   if the user does not supply one via `--client-request-token`.
2. Derived tokens are computed as `SHA256(primary_token + step_name)` (no separator), formatted
   as `<primary_first_8_chars>-<hash_first_8_hex_chars>` (first 8 characters of the primary
   token, a dash, then the first 8 hex characters of the SHA256 hash).
3. Derived tokens are deterministic: given the same primary token and step name, the same
   derived token is always produced.
4. The primary token is logged in command metadata output so that users can reproduce it on
   retry.
5. Auto-generated tokens are random (UUID v4); they are not derived from timestamp or
   hostname.
6. The `--client-request-token` flag is surfaced on all write commands that pass a token to
   AWS APIs.

#### Logic Flow

```
user supplies --client-request-token <value>
  → primary = <value>
user does not supply flag
  → primary = UUID v4 (random)

derived token for step S:
  hash  = SHA256(primary + S)          -- no separator between primary and step
  hex   = lowercase hex encoding of hash
  token = take(8, primary) + "-" + take(8, hex)
```

#### Edge Cases

- User supplies an empty string as the token: treated as user-supplied; no UUID generated.
  AWS API may reject it, which surfaces as an AWS error.
- Two concurrent iidy invocations with auto-generated tokens: tokens are independent (UUID v4
  randomness ensures negligible collision probability).
- Very long step names: SHA256 input length is not bounded; all step name lengths are safe.

#### Error Scenarios

- UUID generation fails (extremely unlikely on a Unix system): treated as an unrecoverable
  internal error with a descriptive message.

#### Complexity Notes

- Deterministic derived tokens allow a caller to pre-compute the token that iidy will use for
  a given step, enabling external idempotency tracking.

---

### US-12-005: Handle SIGINT Gracefully

**As a** Developer or CI Pipeline,
**I want** iidy to exit with code 130 when interrupted with Ctrl-C,
**so that** shell scripts can detect the interrupt correctly and so that runtime backtrace
noise does not appear on the terminal.

#### Acceptance Criteria

1. A SIGINT handler is installed at startup.
2. On SIGINT, the process calls POSIX `_exit(130)` immediately without running finalizers.
3. Exit code 130 is used (128 + signal number 2), matching POSIX shell convention.
4. The runtime's default SIGINT behavior (which prints "interrupted\n" and a backtrace) is
   suppressed.
5. The handler is installed before any command dispatch; it covers the full lifetime of the
   process.
6. Any in-progress spinner or terminal state is abandoned on SIGINT. No cleanup is attempted.

#### Logic Flow

```
startup:
  install SIGINT handler → exit(130) immediately
  ... normal dispatch ...

on Ctrl-C:
  SIGINT handler fires
  _exit(130) called
  process exits immediately without running finalizers
```

#### Edge Cases

- SIGINT received during NTP query: the NTP UDP socket is abandoned; no cleanup needed.
- SIGINT received during a polling loop: the loop is interrupted immediately.
- Multiple SIGINT signals delivered in rapid succession: the first fires the handler; subsequent
  signals have no additional effect because the process is already exiting.

#### Error Scenarios

- Handler installation fails (would require an unsupported OS or sandbox): the exception
  propagates and iidy exits with an error before handling any command.

#### Complexity Notes

- Using `_exit` rather than the runtime's `exitWith` skips finalizers. This is intentional: it
  prevents hang scenarios where a finalizer blocks on a locked resource after interrupt.
- This is a divergence from default runtime behavior and must be re-verified after major
  runtime upgrades.

---

### US-12-006: Detect Terminal Capabilities

**As a** Developer or Reviewer,
**I want** iidy to accurately detect what my terminal supports (color, true-color, width),
**so that** output is rendered with appropriate formatting without manual configuration.

#### Acceptance Criteria

1. Terminal capabilities are computed once at startup and contain:
   - `hasColor`: whether ANSI color codes should be emitted.
   - `width`: terminal width in columns, or absent for non-TTY contexts.
   - `isTty`: whether stdout is a terminal device.
2. `isTty` is set by checking whether stdout is connected to a terminal.
3. `width` is set from the `COLUMNS` environment variable if present and parseable as a
   positive integer. If `COLUMNS` is absent or unparseable and the output is a TTY, width
   defaults to 80. If output is not a TTY, width is absent.
4. `hasColor` follows the precedence chain: `NO_COLOR` set → False; `FORCE_COLOR` set →
   True; otherwise `isTty`.
5. Capability detection is deterministic with respect to the process environment: the same
   environment variables produce the same result every time.
6. Width is used to wrap long lines in interactive output. Non-TTY output is not wrapped.
7. No truecolor capability detection is performed; `COLORTERM` is not read. RGB colors are
   emitted unconditionally when themes use them (see US-06-004).

#### Logic Flow

```
detect terminal capabilities:
  isTty     = stdout connected to a terminal?
  noColor   = NO_COLOR env var set?
  force     = FORCE_COLOR env var set?
  columns   = COLUMNS env var value

  hasColor    = if noColor set → False
                else if force set → True
                else isTty

  width = if COLUMNS parseable as positive int → that value
          else if isTty → 80
          else → absent
```

#### Edge Cases

- `COLUMNS=0`: invalid (not positive); falls back to TTY default (80) or absent.
- `COLUMNS=abc`: unparseable; falls back as above.
- `COLUMNS=120` with stdout redirected to a file: `isTty = False`; width = 120 because the
  environment variable takes precedence over TTY detection for width.
- Running under `script(1)` or similar pseudo-TTY wrappers: `hIsTerminalDevice` may return
  True even though the output is being recorded; color and width detection behave as if
  interactive.

#### Error Scenarios

- TTY detection throws an IO exception (unusual): exception propagates and iidy exits
  before rendering any output.

#### Complexity Notes

- Terminal capabilities are stored as a simple strict record. This avoids space leaks in
  long-running polling loops.
- Width detection intentionally does not query the terminal dimensions via `ioctl`. Using
  `COLUMNS` keeps the implementation portable and testable without a real terminal.

---

### US-12-007: Handle Confirmation Prompts Consistently

**As a** Developer or Platform Engineer,
**I want** all destructive-action confirmation prompts in iidy to have a consistent appearance
and behavior,
**so that** I always know what is being confirmed and can reliably script around them.

#### Acceptance Criteria

1. All confirmation prompts share identical formatting and behavior across the system.
2. The prompt format is:
   - A blank line before the prompt.
   - `"? "` in default color.
   - The message text in bold bright red.
   - `" (y/N) "` in default color.
3. The default answer is **no**. Pressing Enter without input, or providing any input other than
   `y` or `yes` (case-insensitive), confirms the negative.
4. Input `y` or `yes` (case-insensitive) confirms the affirmative.
5. In non-TTY contexts (e.g., CI Pipeline), ANSI codes are suppressed; the prompt text is
   printed as plain text with no color markup.
6. A user declining a confirmation exits with exit code 130 (cancelled). This is the
   same exit code used for SIGINT (Ctrl-C) and signals a clean cancellation, not an
   error. This applies to delete-stack and other confirmation-gated commands.
   Exception: template-approval review rejection exits 1 (a deliberate review
   decision, not a cancellation — see `10-template-approval.md`).
7. The prompt is written to stdout, not stderr.
8. There is no timeout on the confirmation prompt. The process waits indefinitely for input.

#### Logic Flow

```haskell
data ConfirmResult = Confirmed | Declined

requestConfirmation :: Text -> IO ConfirmResult
requestConfirmation prompt:
  hSetBuffering stdin LineBuffering   -- ensure line-at-a-time input
  hSetBuffering stdout NoBuffering    -- ensure prompt appears immediately
  isTty <- hIsTerminalDevice stdout
  putStrLn ""                          -- blank line before prompt
  if isTty
    then putStr "? \ESC[1;91m" <> prompt <> "\ESC[0m (y/N) "
                -- SGR 1 = bold, SGR 91 = bright red
    else putStr "? " <> prompt <> " (y/N) "
  hFlush stdout
  answer <- getLine
  return (if isConfirmation answer then Confirmed else Declined)

isConfirmation :: String -> Bool
isConfirmation answer = map toLower answer `elem` ["y", "yes"]
```

All commands using confirmation prompts follow this pattern:

```
command handler:
  result <- requestConfirmation "Are you sure you want to delete stack X?"
  case result of
    Confirmed -> proceed with destructive operation
    Declined  -> emit "Cancelled." and return exit code 130
```

**Exception:** `template-approval review` rejection returns exit code 1 (a
deliberate review decision), not 130 (cancellation). See `10-template-approval.md`.

**Module:** `Iidy.Confirm` is the single shared implementation used by all
confirmation-gated commands: `delete-stack`, `update-stack` diff preview,
changeset execution, `param review`, and `template-approval review`.

#### Edge Cases

- User types `YES`: downcased to `yes`; treated as affirmative.
- User types `y ` (with trailing space): after stripping, `y`; treated as affirmative.
- User types `no`: treated as negative (default).
- EOF on stdin (e.g., `echo "" | iidy delete-stack`): `getLine` returns `""`; treated as
  negative (default "N").
- Prompt sent to a pipe: no ANSI codes emitted; human-readable text still printed.

#### Error Scenarios

- `getLine` throws an IO exception (e.g., stdin closed unexpectedly): exception propagates;
  iidy exits with an error rather than proceeding with a destructive operation.

#### Complexity Notes

- Centralizing confirmation in a shared module ensures that any future changes to prompt
  formatting or input handling apply uniformly to all confirmation-gated commands.
- The bold-bright-red color is applied to the message only, not to the `"? "` prefix or the
  `"(y/N)"` suffix, matching the Rust reference output.

---

## Testing Requirements

| Story      | Test Type        | Description                                                              |
| ---------- | ---------------- | ------------------------------------------------------------------------ |
| US-12-001  | Unit             | `detectYamlSpec` returns correct variant for each heuristic case         |
| US-12-001  | Unit             | `shouldUseYaml11Compatibility` maps each variant to Bool correctly        |
| US-12-001  | Unit             | Empty input → `UnknownSpec`                                              |
| US-12-001  | Unit             | `%YAML 1.1` on line 6 falls through to heuristic                        |
| US-12-001  | Unit             | CFN file with apiVersion wins on CFN check (order matters)               |
| US-12-001  | Property         | Any input with explicit `%YAML 1.1` directive → `ExplicitV11`            |
| US-12-002  | Unit             | `NO_COLOR` set → `tcHasColor = False` regardless of TTY                  |
| US-12-002  | Unit             | `FORCE_COLOR` set, `NO_COLOR` absent → `tcHasColor = True`               |
| US-12-002  | Unit             | Both set → `NO_COLOR` wins                                               |
| US-12-002  | Unit             | `COLORTERM=truecolor` → `tcHasTrueColor = True`                          |
| US-12-002  | Unit             | `COLORTERM=Truecolor` (capital T) → `tcHasTrueColor = False`             |
| US-12-003  | Unit (mock)      | Mock time provider returns fixed timestamp                               |
| US-12-003  | Unit (mock)      | NTP failure path falls back to system time without error                 |
| US-12-003  | Unit             | NTP epoch offset constant is exactly 2,208,988,800                       |
| US-12-004  | Unit             | Derived token is deterministic for same primary + step                   |
| US-12-004  | Unit             | Derived token format matches `<8hex>-<8hex>`                             |
| US-12-004  | Property         | Two different step names produce different derived tokens                 |
| US-12-005  | Integration      | SIGINT handler installed before dispatch (verified by handler presence)  |
| US-12-005  | Manual           | `Ctrl-C` during polling → exit 130, no backtrace noise                  |
| US-12-006  | Unit             | `COLUMNS=120` → `tcWidth = Just 120`                                     |
| US-12-006  | Unit             | `COLUMNS=0` non-TTY → `tcWidth = Nothing`                               |
| US-12-006  | Unit             | `COLUMNS=abc` non-TTY → `tcWidth = Nothing`                             |
| US-12-006  | Unit             | Non-TTY, no COLUMNS → `tcWidth = Nothing`                               |
| US-12-007  | Unit             | `"y"` → True; `"yes"` → True; `"YES"` → True                            |
| US-12-007  | Unit             | `""` → False; `"no"` → False; `"n"` → False                             |
| US-12-007  | Unit             | Decline returns exit code 130 (cancelled, not error)                     |
| US-12-007  | Snapshot         | Prompt output matches expected ANSI format in TTY context                |

All tests use `MockTimeProvider` for time-dependent assertions. No live NTP queries occur in the
test suite. No real AWS calls are made.

---

## Cross-References

- `DIVERGENCES.md` — Error color check uses stderr TTY (not stdout); `--color` flag values
  differ from Rust; PowerShell completion not implemented.
- `06-output-system.md` — Output dispatch and renderer architecture.
- `05-cfn-operations.md` — CommandMetadata and FinalCommandSummary timestamp usage.
- `08-aws-integration.md` — NTP time provider, SNTP protocol details.
