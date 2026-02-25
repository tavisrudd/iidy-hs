# Stderr Usage Audit & Corrections -- Review Plan

**Date**: 2026-02-25
**Session**: `8334c9cc-a311-4d42-937f-314d40b539f5`
**References**: Rust source (`~/src/iidy/src/main.rs`, `render.rs`, `cfn/`), Unix conventions

## Context

Audit of all direct stdout/stderr writes across the codebase (excluding the
output pipeline renderers, which are addressed in the noisy-tests handoff).
The question: are errors and diagnostics going to stderr, and normal output
going to stdout, per Unix conventions and Rust parity?

## Audit Results

### Correct usage (no action needed)

These are all fine:

| File                       | Line(s)     | Handle        | Content                       | Verdict |
|----------------------------|-------------|---------------|-------------------------------|---------|
| `Render.hs`                | 55, 71      | stderr        | YAML parse/preprocess errors  | Correct |
| `Render.hs`                | 81          | stderr        | Invalid JMESPath query        | Correct |
| `Render.hs`                | 93          | stderr        | Unsupported format error      | Correct |
| `Render.hs`                | 104         | stdout        | Rendered template output      | Correct |
| `Render.hs`                | 110         | stderr        | File exists conflict          | Correct |
| `GetImport.hs`             | 34, 41      | stderr        | Import errors                 | Correct |
| `GetImport.hs`             | 48, 51, 55  | stdout        | Import data output            | Correct |
| `Explain.hs`               | 18          | stderr        | Usage error (no args)         | Correct |
| `Explain.hs`               | 28          | stderr        | Unknown error code            | Correct |
| `Explain.hs`               | 30-34       | stdout        | Error explanation text        | Correct |
| `Demo.hs`                  | 68, 77, 84  | stderr        | Parse/script errors           | Correct |
| `Demo.hs`                  | 223, 225    | stdout/stderr | Subprocess output forwarding  | Correct |
| `Demo.hs`                  | 240-265     | stdout        | Interactive demo display      | Correct |
| `Aws/Sts.hs`               | 29          | stderr        | STS warning                   | Correct |
| `Cli/Help.hs`              | 448         | stderr        | `putStrLnErr` helper          | Correct |
| `Cli/Help.hs`              | 41, 77, etc | stdout        | Help text display             | Correct |
| `Cli/Parser.hs`            | 45          | stdout        | Shell completion output       | Correct |
| `Confirm.hs`               | 23-27       | stdout        | Interactive prompt            | Correct |
| `Params/Review.hs`         | 55-73       | stdout        | Parameter review output       | Correct |
| `Main.hs`                  | 80-103      | stderr        | AWS error messages            | Correct |
| `Main.hs`                  | 239-274     | stdout        | Command results               | Correct |
| `Main.hs`                  | 333         | stderr        | Unsupported shell error       | Correct |
| `Main.hs`                  | 451         | stderr        | Fatal error + exit            | Correct |
| `Yaml/Errors/Display.hs`   | 58          | stderr        | TTY check for error colors    | Correct |
| `Output/Terminal.hs`        | 20          | stdout        | TTY check for capabilities    | Correct |
| `Output/Renderers/*.hs`    | 120, 930    | stderr        | Template stderr lines         | Correct |

### Issues to fix

#### A. `Render.hs:114` — status message on stderr (debatable, matches Rust)

```
TIO.hPutStrLn stderr ("Template rendered to: " <> T.pack outPath)
```

**Rust** (`src/render.rs:67`): `eprintln!("Template rendered to: {}", args.outfile)`

Verdict: **Matches Rust. Keep as-is.** This is a deliberate choice — when output
goes to a file (`--outfile`), the status message goes to stderr so it doesn't
contaminate the redirected stdout. This is correct Unix behavior.

#### B. `ConvertStack.hs:430,435,443,473` — "Wrote X" status messages on stderr

```haskell
hPutStrLn stderr $ "Wrote " <> policyPath
hPutStrLn stderr $ "Wrote " <> originalPath
hPutStrLn stderr $ "Wrote " <> cfnTemplatePath
hPutStrLn stderr $ "Wrote " <> argsPath
```

**Verdict**: **Debatable but defensible.** `convert-stack` writes multiple files
and reports each one. Since the command's "output" is the files themselves (not
stdout), status messages to stderr is reasonable. The Rust source uses
`eprintln!` for similar messages. **Keep as-is** for Rust parity.

#### C. `ConvertStack.hs:521` — "Writing SSM parameter" progress on stderr

```haskell
hPutStrLn stderr $ "Writing SSM parameter: " <> T.unpack name
```

**Verdict**: Same pattern as B. Progress messages about side-effects. **Keep as-is.**

#### D. `ConvertStack.hs:459` — error on stderr

```haskell
hPutStrLn stderr "Error: --move-params-to-ssm requires a project name"
```

**Verdict**: **Correct.** Error → stderr.

#### E. `InitStackArgs.hs:98` — file conflict warning on stdout (BUG)

```haskell
putStrLn $ filename <> " already exists! See help [-h] for overwrite options"
```

This is a warning/error message going to **stdout** instead of stderr.

**Rust behavior**: The Rust `init-stack-args` uses `eprintln!` for the
already-exists case.

**Fix**: Change `putStrLn` to `hPutStrLn stderr`.

#### F. `InitStackArgs.hs:101` — success message on stdout (debatable)

```haskell
putStrLn $ filename <> " has been created!"
```

**Verdict**: Status/confirmation message. Rust uses `eprintln!` for this too.
For Rust parity, change to stderr. But this is low priority — it's a minor
style inconsistency, not a functional bug.

### Summary

| Issue                                 | Severity | Action                                                |
|---------------------------------------|----------|-------------------------------------------------------|
| E: InitStackArgs warning to stdout    | Medium   | Fix: `putStrLn` → `hPutStrLn stderr`                 |
| F: InitStackArgs success to stdout    | Low      | Fix for Rust parity: `putStrLn` → `hPutStrLn stderr` |
| A-D: ConvertStack/Render stderr msgs  | None     | Already correct (matches Rust)                        |

## Chunks

### Chunk 1: Fix InitStackArgs stderr usage

Two-line change in `src/Iidy/InitStackArgs.hs`:
- Line 98: `putStrLn` → `hPutStrLn stderr`
- Line 101: `putStrLn` → `hPutStrLn stderr`
- Add `import System.IO (hPutStrLn, stderr)` if not present

```haskell
writeIfAbsent :: FilePath -> String -> Bool -> IO ()
writeIfAbsent filename content force = do
  exists <- doesFileExist filename
  if exists && not force
    then hPutStrLn stderr $ filename <> " already exists! See help [-h] for overwrite options"
    else do
      writeFile filename content
      hPutStrLn stderr $ filename <> " has been created!"
```

### Chunk 2: Verify no other misrouted output

Run a final grep to confirm no remaining `putStrLn`/`putStr` calls in `src/`
that should be stderr. The audit above covers everything, but a quick
verification pass is good practice.

## Codebase Reference

| What                       | Where                                            |
|----------------------------|--------------------------------------------------|
| InitStackArgs writeIfAbsent | `src/Iidy/InitStackArgs.hs:94-101`              |
| ConvertStack stderr writes  | `src/Iidy/Cfn/Operations/ConvertStack.hs:430-521`|
| Render.hs stderr writes     | `src/Iidy/Render.hs:55-114`                     |
| Main.hs error handler       | `app/Main.hs:73-103`                            |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

| Chunk | Delegate? | Agent  | Notes                    |
|-------|-----------|--------|--------------------------|
| 1     | Yes       | Sonnet | Two-line fix             |
| 2     | No        | Main   | Quick grep verification  |

This is a 1-commit fix. Can be combined with other work.

## Workflow Instructions

- This is a tiny fix — can be done as part of any session
- After fixing, run tests to confirm nothing breaks
- The `writeIfAbsent` function has no test coverage, so this is a safe mechanical change

## Progress

- [ ] Chunk 1: Fix InitStackArgs.hs putStrLn → hPutStrLn stderr
- [ ] Chunk 2: Final verification grep

## Handoff Notes

(none yet)
