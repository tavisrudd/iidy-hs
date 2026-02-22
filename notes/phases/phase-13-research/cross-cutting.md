# Cross-Cutting Issues

Issues that affect multiple commands, not specific to any single operation.

## 1. CommandMetadata (affects all write operations)

Rust emits `CommandMetadata` as the first output for all write operations:
create-stack, update-stack, delete-stack, create-or-update, create-changeset,
exec-changeset, template-approval-request, template-approval-review.

CommandMetadata includes: environment, region, profile, IAM service role,
current IAM principal, credential source, CLI arguments, iidy version,
client request token + derived tokens.

**Haskell status**: `renderCommandMetadata` exists in Interactive.hs (line 297)
and handles all fields. But NO operation ever emits `OdCommandMetadata`.

**Fix**: Create a `buildCommandMetadata` helper that constructs `CommandMetadata`
from `CfnContext` + `Cli` options. Call it at the start of each write operation.

## 2. FinalCommandSummary (affects all write operations)

Rust emits `FinalCommandSummary` as the last output for all write operations.
Shows elapsed time and success/failure with emoji.

**Haskell status**: `renderFinalCommandSummary` exists in Interactive.hs (line 529).
But NO operation ever emits `OdFinalCommandSummary`.

**Fix**: After each write operation completes, emit `OdFinalCommandSummary` with
elapsed time from `ctxElapsedSeconds` and success based on exit code.

## 3. TokenInfo (affects create, update, exec-changeset)

Rust emits `TokenInfo` showing the client request token before the API call.

**Haskell status**: `OdTokenInfo` is explicitly ignored in renderOutputData (line 147:
`OdTokenInfo _ -> pure ()`). This is intentional — token info is not rendered
in interactive mode in Rust either. **No action needed.**

## 4. OperationComplete (affects all polling operations)

Rust emits `OperationComplete` after a stack reaches terminal status, showing
elapsed seconds.

**Haskell status**: `renderOperationComplete` exists (line 717). Never emitted.

**Fix**: After `pollForCompletion` returns, emit `OdOperationComplete` with
elapsed time before collecting stack contents.

## 5. Region Resolution Priority

`resolveRegion` in Config.hs checks `AWS_DEFAULT_REGION` before `AWS_REGION`.
AWS SDK standard (and Rust aws-config) checks `AWS_REGION` first.

**Fix**: Swap the order in `resolveRegion`.

**File**: `src/Iidy/Aws/Config.hs` line 64.

## 6. Section Headings in Renderer

`renderStackEvents` never prints `sedTitle` as a heading.
`renderStackContents` never prints "Stack Resources:" heading.

Both issues affect describe-stack, delete-stack (pre-confirmation), watch-stack,
and any command that renders these OutputData variants.

**Fix**: Add heading prints in both renderer functions.

**File**: `src/Iidy/Output/Renderers/Interactive.hs` lines 392, 437.

## 7. Console URL Encoding

`buildConsoleUrl` in DescribeStack.hs URL-encodes slashes in ARN.
Rust does NOT encode for stack info URLs (only for changeset URLs).

**Fix**: Remove `T.replace "/" "%2F"` from `buildConsoleUrl`.

**File**: `src/Iidy/Cfn/Operations/DescribeStack.hs` line 149.

## 8. AWS Auth Timeout

`Amazonka.newEnv Amazonka.discover` hangs on instance metadata when no credentials.
Rust aws-config also has no explicit timeout, but in practice times out faster.

**Fix**: Wrap `Amazonka.newEnv Amazonka.discover` in `System.Timeout.timeout`.
On timeout, print credential-not-found error with suggestions.

**File**: `src/Iidy/Aws/Config.hs` line 39.

## 9. Spinners

Spinner module exists but is never wired into operations. The Rust version shows
spinners with section titles while sections load asynchronously.

Since Haskell operations are synchronous, the main use case is showing a spinner
during `pollForCompletion` idle periods (the 2s delays between polls).

**Fix**: In `pollForCompletion`, start a spinner before `threadDelay`, clear it
before emitting new events.

## 10. STS GetCallerIdentity for Error Context

Multiple commands need STS GetCallerIdentity for error context (StackAbsentInfo).
This should be a shared utility.

**Fix**: Add `getCallerIdentity :: CfnContext -> IO (Text, Text)` to
`Iidy.Cfn.StackOperations` or a new `Iidy.Aws.Sts` module. Returns (account, arn).
Falls back to ("unknown", "unknown") on failure.

## Priority Order

1. Section headings (6) — 2-line fix, affects all commands
2. Console URL (7) — 1-line fix
3. Region priority (5) — 2-line fix
4. STS utility (10) — enables error fixes
5. StackAbsentInfo in describe/delete (per-command)
6. Pre-confirmation display in delete-stack
7. StackDefinition in create/update/watch
8. CommandMetadata infrastructure
9. FinalCommandSummary infrastructure
10. Auth timeout (8)
11. Spinners (9)
12. Changeset paths in create-or-update/update-stack
13. describe-stack-drift completion
