# SSM Global Configuration (applyGlobalConfiguration) -- Feature Implementation

**Date**: 2026-03-01
**Session**: `be724d39-a640-450d-bf6b-bdc994416bef`
**References**: Rust `src/cfn/stack_args.rs:324-393`, JS `src/cfn/loadStackArgs.ts:27-60`

## Context

iidy supports global configuration via SSM Parameter Store under the `/iidy/`
path. When loading stack args, both the Rust and JS implementations call
`applyGlobalConfiguration` which:

1. Calls `SSM.GetParametersByPath(Path="/iidy/", WithDecryption=true)`
2. For each parameter found:
   - `/iidy/default-notification-arn` -- validates the SNS topic ARN exists
     (via `SNS.GetTopicAttributes`), then appends it to `NotificationARNs`
   - `/iidy/disable-template-approval` -- if value matches `/true/i` and
     `ApprovedTemplateLocation` is set, removes it (disables template approval)
3. Silently continues if SSM is not accessible (catch-all error handler)

This feature is **not yet ported** to iidy-hs. The `amazonka-sns` dependency
was just removed; it needs to be restored when this is implemented.

## What to Implement

### Function: `applyGlobalConfiguration`

```haskell
-- In a new module Iidy.Cfn.GlobalConfig or added to StackArgsLoader
applyGlobalConfiguration
  :: Amazonka.Env
  -> StackArgs
  -> IO StackArgs  -- returns modified StackArgs
```

Logic:
1. Call `SSM.GetParametersByPath` with path `/iidy/`, decryption enabled
2. Match on parameter names:
   - `/iidy/default-notification-arn` -> call `applySnsNotification`
   - `/iidy/disable-template-approval` -> if value is "true" (case-insensitive)
     and `saApprovedTemplateLocation` is `Just _`, set it to `Nothing`
3. Catch all exceptions and silently return unmodified `StackArgs`

### Function: `applySnsNotification`

```haskell
applySnsNotification :: Amazonka.Env -> Text -> StackArgs -> IO StackArgs
```

Logic:
1. Call `SNS.GetTopicAttributes` with the topic ARN
2. If success: append ARN to `saNotificationArns`
3. If failure: log warning "iidy's default NotificationARN set in this region
   is invalid: {arn}" and return unmodified

### Integration point

In `StackArgsLoader.hs`, after line 104 (after `valueToStackArgs` succeeds),
call `applyGlobalConfiguration` with the AWS env and stack args. This requires
the Amazonka `Env` to be available at this point -- currently `loadStackArgs`
doesn't take one. Two options:

**Option A**: Pass `Amazonka.Env` into `loadStackArgs` (adds a parameter).
The callers in `app/Main.hs` already have the env available.

**Option B**: Create the env inside `loadStackArgs` from `mergedAws`. More
self-contained but duplicates env creation.

Recommend **Option A** -- simpler, follows the pattern used everywhere else.

## Dependencies to Restore

Add back to `iidy-hs.cabal` library build-depends:
```
    , amazonka-sns
```

Add back to `flake.nix` haskellDeps:
```
        hpkgs.amazonka-sns
```

## Codebase Reference

| What                           | Where                                              |
|--------------------------------|-----------------------------------------------------|
| `loadStackArgs`                | `src/Iidy/Cfn/StackArgsLoader.hs` (line 65)        |
| `StackArgs` type               | `src/Iidy/Cfn/Types.hs`                            |
| `saNotificationArns` field     | `src/Iidy/Cfn/Types.hs`                            |
| `saApprovedTemplateLocation`   | `src/Iidy/Cfn/Types.hs`                            |
| Callers of `loadStackArgs`     | `app/Main.hs` (grep for `loadStackArgs`)           |
| SSM loader (existing pattern)  | `src/Iidy/Yaml/Imports/Loaders/Ssm.hs`             |
| Rust implementation            | `~/src/iidy/src/cfn/stack_args.rs` (lines 324-393)  |
| JS implementation              | `~/src/iidy-js/src/cfn/loadStackArgs.ts` (lines 27-60) |
| JS tests                       | `~/src/iidy-js/src/tests/test-global-configuration.ts` |

## Build/Test Commands

Per CLAUDE.md -- `run-quiet` wrapper for `cabal build` and `cabal test`.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Isolated feature with clear spec, existing patterns for SSM and SNS
  API calls in the codebase. The function signatures and logic are fully specified
  above.

## Workflow Instructions

1. Read this file first
2. Restore `amazonka-sns` dep in cabal + flake.nix
3. Implement `applyGlobalConfiguration` + `applySnsNotification`
4. Wire into `loadStackArgs` (Option A)
5. Add tests (mock-based, following JS test patterns)
6. Build clean, all tests pass
7. Update Progress below

## Progress

- [ ] Restore `amazonka-sns` dependency
- [ ] Implement `applyGlobalConfiguration` and `applySnsNotification`
- [ ] Wire into `loadStackArgs` with `Amazonka.Env` parameter
- [ ] Update callers in `app/Main.hs`
- [ ] Add tests (mock SSM/SNS responses)
- [ ] Build clean + all tests pass

## Handoff Notes

### Session 41 (2026-03-01)
**Blocker**: `amazonka-sns` is incompatible with GHC 9.10.3 / base 4.20.
Cabal cannot resolve the dependency. Implementation exists as untracked
`src/Iidy/Cfn/GlobalConfig.hs` and in backup patch `~/iidy-hs-all-agent-changes.patch`.

**Options to unblock**:
1. Use raw `amazonka` to construct SNS.GetTopicAttributes request manually (no amazonka-sns needed)
2. Find/build a compatible amazonka-sns version
3. Skip SNS validation — just append the ARN without validating via GetTopicAttributes
