# Phase 12: Completion Audit vs Rust

**Status**: NOT STARTED
**Depends on**: Phases 10-11

## Purpose

Final systematic audit comparing every user-visible behavior in iidy-rs against
iidy-hs. Previous "completion" declarations (Session 22) missed the entire output
pipeline. This phase exists to prevent that from happening again.

## Chunks

### 12.1: Command-by-Command Behavioral Parity Audit

For EVERY command, run both Rust and Haskell against the same input (mocked or
fixture) and diff the output. Document any divergences.

- [ ] `render` — YAML preprocessing output (already snapshot-tested, verify)
- [ ] `render --format json` — JSON output mode
- [ ] `render` error cases — enhanced error display (already snapshot-tested)
- [ ] `describe-stack` — stack definition, events table, resources/outputs/exports
- [ ] `list-stacks` — table columns, alignment, env colors, lifecycle icons, tag display
- [ ] `watch-stack` — live event stream, colored statuses, timing, terminal status detection
- [ ] `create-stack` — metadata header, progress events, final summary
- [ ] `update-stack` — same as create-stack
- [ ] `create-or-update` — same, with exists-or-not detection
- [ ] `delete-stack` — confirmation prompt, progress events
- [ ] `create-changeset` — changeset display with Add/Modify/Remove
- [ ] `exec-changeset` — changeset execution with events
- [ ] `get-stack-template` — raw template output
- [ ] `describe-stack-drift` — drift table, property differences
- [ ] `estimate-cost` — cost URL output
- [ ] `lint-template` — validation warnings
- [ ] `convert-stack` — YAML file generation, SSM migration
- [ ] `init-stack-args` — generated YAML/JSON output
- [ ] `template-approval-request` — S3 upload feedback
- [ ] `template-approval-review` — diff display, approval status
- [ ] `explain` — error code explanations
- [ ] `demo` — playback, banner, masking
- [ ] `param get/set/get-by-path/get-history/review` — parameter operations
- [ ] `get-import` — resource spec output
- [ ] `completion` — shell completion scripts
- [ ] `--help` (global and per-command) — already verified, re-check

### 12.2: Output Mode Audit

- [ ] Interactive mode (TTY): colors, spinners, section headings, tables
- [ ] Plain mode (pipe/CI): same content, no ANSI, no spinners
- [ ] JSON mode (`--output json`): valid JSONL, all fields present
- [ ] `--color=always` forces colors even in pipe
- [ ] `--color=never` suppresses colors even on TTY
- [ ] `--theme=dark/light/high-contrast` produce correct color codes
- [ ] `NO_COLOR` env var respected
- [ ] `FORCE_COLOR` env var respected (Haskell addition, document)

### 12.3: Error Handling Audit

- [ ] YAML parse errors — enhanced display with colors, carets, guidance
- [ ] YAML preprocess errors — all 6 error types (variable, type, CFN, syntax, tag, lookup)
- [ ] AWS operation errors — `dieTxt` format matches Rust `eprintln!("{e:?}")`
- [ ] Uncaught exceptions — `handleUncaughtException` format
- [ ] Missing file errors — IO exception formatting
- [ ] Invalid CLI args — optparse-applicative error format
- [ ] Stack not found — error message and suggestions
- [ ] Ctrl-C handling — clean exit, no stack trace

### 12.4: Feature Completeness Checklist

Re-verify every item from the original workplan:

- [ ] YAML 1.1 / 1.2 auto-detection and compatibility
- [ ] All iidy tags: `!$`, `!$if`, `!$eq`, `!$not`, `!$let`, `!$map`, `!$concatMap`,
  `!$merge`, `!$concat`, `!$split`, `!$join`, `!$fromPairs`, `!$mapListToHash`,
  `!$groupBy`, `!$toJsonString`, `!$toYamlString`, `!$parseJson`, `!$parseYaml`,
  `!$jmespath`, `!$mapValues`, `!$deepMerge`, `!$default`
- [ ] CloudFormation intrinsics: `!Ref`, `!Sub`, `!GetAtt`, `!Join`, `!Select`,
  `!Split`, `!FindInMap`, `!Base64`, `!Cidr`, `!GetAZs`, `!ImportValue`,
  `!Transform`, `!And`, `!Or`, `!Not`, `!Equals`, `!If`, `!Condition`
- [ ] Import sources: file, env var, SSM parameter, CFN stack output, Git
- [ ] Handlebars: variables, helpers (`#if`, `#unless`, `#each`, `#with`,
  `lookup`, `toUpperCase`, `toLowerCase`, `toJson`, `toYaml`,
  `base64Encode`, `base64Decode`, `sha256`, `md5`, `regexReplace`)
- [ ] JMESPath queries
- [ ] JSON Schema validation
- [ ] NTP time sync
- [ ] Template hashing and S3 versioning
- [ ] Demo command with playback
- [ ] `explain` command with error code database

### 12.5: Performance Comparison

- [ ] Render a complex template: compare wall time (should be <2x Rust)
- [ ] Memory usage comparison (already profiled at 316KB, re-verify)
- [ ] Binary size comparison

### 12.6: Documentation of Known Divergences

Produce a final `DIVERGENCES.md` documenting every intentional difference:

- [ ] CLI help formatting (clap vs optparse-applicative)
- [ ] serde_yaml snapshot format differences
- [ ] `FORCE_COLOR` support in error colors (Haskell addition)
- [ ] Any other differences found during audit

## Gate Criteria

```bash
# Every command tested against Rust oracle
# Every output mode verified
# Every error path verified
# Zero undocumented divergences
# All tests pass
cabal test
scripts/snapshot-compare.sh              # 37/37
scripts/error-snapshot-compare.sh        # 49/49
# DIVERGENCES.md committed with all known differences
```

## Iterative Completion Process

This phase is NOT a single pass. It follows an audit→fix→re-audit loop:

1. **Audit**: Run through all chunks above, documenting every gap and divergence
2. **Triage**: For each gap, determine:
   - Fixable offline (mock-testable)? → Create a new phase (13, 14, ...) with specific fix plan
   - Requires live AWS? → Document in DIVERGENCES.md as "untestable offline, verified by code review"
   - Intentional divergence? → Document in DIVERGENCES.md with rationale
3. **Fix phases execute**: Implement fixes from triage
4. **Re-audit**: Run the full audit again after fix phases complete
5. **Repeat** until re-audit finds zero new gaps that are fixable offline

The audit is only considered PASSED when a full re-run of all chunks produces
zero new issues. Previous sessions declared completion prematurely (Session 22
missed the entire output pipeline). This loop prevents that.

### What "done" means

"Done" = every behavior that can be tested offline matches Rust, with:
- Automated tests covering each behavior
- Any remaining gaps documented with clear justification (e.g., "requires live AWS")
- No `show`-based debug output reaching users
- No dead code (unused renderers, unwired pipelines)
- DIVERGENCES.md committed and reviewed

### What's testable offline vs not

**Testable offline (must match Rust):**
- All YAML rendering (fixtures)
- All error display (fixtures)
- Renderer formatting (mock OutputData → formatted text)
- CLI parsing and help output
- Color/theme/mode selection logic
- JSON renderer output format
- Table formatting, column alignment, truncation
- Environment color detection
- Status color mapping
- Event formatting
- Changeset display
- Template hashing
- NTP packet construction (no network needed for format test)
- JSON Schema validation
- JMESPath evaluation
- Handlebars rendering
- Demo script parsing and playback logic

**NOT testable offline (verify by code review only):**
- Actual AWS API calls (all behind mock boundaries)
- Real terminal spinner animation timing
- Live polling loop behavior with real AWS events
- S3 upload/download for template approval
- SSM parameter read/write
- CloudFormation stack creation/deletion actual behavior
- Network NTP time sync

## Notes

- This is a VERIFICATION phase, not an implementation phase. If issues are found,
  they get filed back to new phases, not fixed inline during audit.
- Use sub-agents for parallel command-by-command comparison.
- The Rust oracle at `~/src/iidy/target/debug/iidy` requires `nix develop ~/src/iidy`.
- For commands that need AWS (most CFN ops), compare code paths and mock behavior
  rather than running live. Compare rendered output from mock data.
- Each audit pass should be SHORT — mostly verification, minimal code changes.
  Fix work goes into separate phases.

## On Successful Completion

When the audit loop passes clean (zero new offline-testable gaps found on a full
re-audit), the session that verifies this MUST:

1. Commit all final docs (DIVERGENCES.md, updated phase docs, WORKPLAN.md)
2. `touch .ralph-stop` — this signals the ralph loop to stop spawning new sessions
3. Exit cleanly

The `.ralph-stop` file is the definitive "we are done" signal. Do NOT touch it
until the audit loop has passed clean. Any session that finds new gaps should
NOT touch it — instead create fix phases and exit for the next session.
