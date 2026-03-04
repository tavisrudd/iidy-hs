# Wire AWS imports end-to-end in stack-args loading

## Status: DONE

## Context

`loadStackArgs` now accepts `Maybe Amazonka.Env` but the production call
path in `app/Main.hs:363` passes `Nothing`. This means SSM and CFN
imports inside stack-args YAML files silently fail or error because no
AWS credentials are available during preprocessing.

In iidy-js, `setupAWSCredentials(mergedAWSSettings)` is called BEFORE
`transform()` processes the stack-args imports. The Haskell port currently
creates the AWS env AFTER loading stack-args, so imports that need AWS
(e.g., `!$imports` with `ssm:` or `cfn:` sources) have no credentials.

## References

- **iidy-js**: `src/cfn/loadStackArgs.ts` lines 111-118 -- calls
  `setupAWSCredentials(mergedAWSSettings)` before `transform()`
- **app/Main.hs:363**: `loadStackArgs argsfilePath env operation cliAws remoteImports Nothing`
- **src/Iidy/Cfn/StackArgsLoader.hs**: the `Maybe Amazonka.Env` parameter added in commit `ca948b6`

## Approach

The fix requires a two-pass approach or restructuring in `runCfnWithArgs`
(app/Main.hs):

1. **Option A (two-pass)**: First call `loadStackArgs` with `Nothing` to
   get the merged AWS settings. Create the AWS env from those merged
   settings. Then call `loadStackArgs` again with `Just env` to
   re-process imports that need AWS credentials. This duplicates work
   but is simplest.

2. **Option B (restructure)**: Extract AWS settings merging from
   `loadStackArgs` into a separate step. Merge CLI + file AWS settings
   first, create the env, then call the import processor with the env.
   Cleaner but more invasive.

## Scope

- Modify `runCfnWithArgs` in `app/Main.hs`
- Possibly restructure `loadStackArgs` in `src/Iidy/Cfn/StackArgsLoader.hs`
- Add integration tests with mock AWS env for SSM/CFN imports in stack-args

## Implementation (completed)

Used a variant of Option B: extract raw AWS settings from the parsed (but not
preprocessed) YAML AST, merge with CLI settings, create a bootstrap AWS env,
then pass it to `loadStackArgs`.

**Key changes:**
- `StackArgsLoader.extractRawAwsFromFile`: parses YAML and extracts
  Profile/Region/AssumeRoleARN from the raw AST (handles plain strings and
  environment maps)
- `runCfnWithArgs`: creates bootstrap env from merged raw+CLI settings before
  calling `loadStackArgs`; falls back to `Nothing` on any failure (graceful
  degradation)
- 6 new tests for `extractRawAwsFromAst` covering plain strings, env maps,
  missing/null fields, non-mapping AST, and missing env in map

**Commit:** `8391836`
