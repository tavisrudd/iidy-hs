# Phase 10: Output Pipeline Wiring

**Status**: NOT STARTED
**Depends on**: Phases 1-9

## Problem Statement

The output system has three layers, each progressively less wired:

1. **Renderers** (Interactive 855 LOC, Json 488 LOC) — fully implemented, never called
2. **OutputData types** (21 constructors) — defined, used by 2 commands (`describe-stack`,
   `list-stacks`), but printed via `show` instead of the renderer
3. **CFN write operations** — return `Either Text Int`, produce zero user-visible output
   (no progress, no events, no status), just an exit code

In Rust, every CFN command goes through `run_command_handler!` which creates an
`OutputManager` → `InteractiveRenderer`, and the command emits `OutputData` throughout.
Users see colored status, spinners, event streams, changeset tables, etc.

## Chunks

### 10.1: Wire Renderer into Main.hs

**Goal**: Replace `showOutputData` (which just calls `show`) with actual renderer dispatch.

- [ ] Create `mkOutputOptions :: GlobalOpts -> OutputOptions` that maps:
  - `goColor` → color enable logic (Always/Never/Auto)
  - `goTheme` → `ooColorTheme`
  - `goOutputMode` → `ooMode`
- [ ] In `runCommand`, create `DynamicOutputManager` from `GlobalOpts`
- [ ] Replace `mapM_ (TIO.putStrLn . showOutputData) datas` with renderer calls
- [ ] For `describe-stack` and `list-stacks`: route `[OutputData]` through renderer
- [ ] Delete `showOutputData :: OutputData -> Text` (it's `T.pack . show` — debug only)
- [ ] Verify `renderOutputData` in Interactive.hs handles all OutputData constructors
  that these commands emit (`OdStackDefinition`, `OdStackEvents`, `OdStackContents`,
  `OdStackList`)

**Test**: Unit test: render `OdStackDefinition` with `defaultColors` → contains ANSI codes.
Render with `noColors` → no ANSI. Render with `--theme=light` → different color values.

### 10.2: Wire watch-stack Through Renderer

**Goal**: Replace raw `TIO.putStrLn` callback with renderer event display.

- [ ] `watchStack` currently takes `Text -> IO ()` callback for events
- [ ] Change to emit `OdNewStackEvents` through the renderer instead
- [ ] Renderer shows colored status, resource type, logical ID, duration
- [ ] Initial stack state shown as `OdStackDefinition` + `OdStackEvents` (past events)
- [ ] Terminal status shown as `OdOperationComplete`

**Test**: Mock event list → rendered output contains colored status text.

### 10.3: Wire Write Operations Through Renderer

**Goal**: `create-stack`, `update-stack`, `delete-stack`, etc. emit OutputData.

Current state: these return `Either Text Int` with zero user output.
Rust emits: `OdCommandMetadata` → `OdStackDefinition` → `OdNewStackEvents` (live) →
`OdStackContents` → `OdFinalCommandSummary`.

- [ ] Add `DynamicOutputManager` (or renderer) parameter to write operation functions
- [ ] Emit `OdCommandMetadata` at start (region, env, credentials info)
- [ ] Emit `OdStackDefinition` after stack lookup/creation
- [ ] During `pollForCompletion`, emit `OdNewStackEvents` via renderer callback
- [ ] On completion, emit `OdStackContents` + `OdFinalCommandSummary`
- [ ] For `delete-stack`: emit `OdConfirmationPrompt` before proceeding
- [ ] For `create-changeset`/`exec-changeset`: emit `OdChangeSetResult`

**Test**: Mock operations with canned events → verify renderer produces expected sections.

### 10.4: JSON Output Mode

**Goal**: `--output json` emits JSONL through `JsonRenderer`.

- [ ] Wire `goOutputMode` → select `JsonRenderer` vs `InteractiveRenderer`
- [ ] In `OutputJson` mode: route all `OutputData` through `renderOutputDataJson`
- [ ] Verify JSONL format: one JSON object per line with type/timestamp/data

**Test**: Render `OdStackDefinition` in JSON mode → valid JSON with expected fields.

### 10.5: Plain Mode

**Goal**: Non-TTY or `--output plain` uses renderer with no colors/spinners.

- [ ] Already handled by `plainInteractiveOptions` (`ioEnableAnsi = False`)
- [ ] Verify auto-detection: pipe output → plain mode selected
- [ ] Verify `--color=never` → no ANSI codes even on TTY

**Test**: Render sample OutputData with `plainInteractiveOptions` → no `\ESC[` in output.

## Gate Criteria
```bash
cabal test                              # all tests pass, zero warnings
# describe-stack produces formatted, colored output (not show dump)
# list-stacks produces formatted table output
# watch-stack shows colored event stream
# --color=never suppresses all ANSI in output
# --output json produces valid JSONL
# write operations emit progress/status output
```

## Notes

- `dieTxt` for fatal errors (missing args, AWS connection failures) stays plain.
  Rust also uses `eprintln!("{e:?}")` for these. Only operational output goes through renderer.
- `handleUncaughtException` stays plain — matches Rust.
- Spinners are a stretch goal — they require async background threads.
  Core rendering (colors, tables, section formatting) comes first.
- The renderers are already implemented. This phase is about wiring, not writing new renderers.
- All testing uses mock data. No real AWS calls.
