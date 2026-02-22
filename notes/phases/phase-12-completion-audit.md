# Phase 12: Completion Audit vs Rust

**Status**: IN PROGRESS (12.1-12.2 done, 12.3-12.6 remaining verification)
**Depends on**: Phases 10-11

## Purpose

Final systematic audit comparing every user-visible behavior in iidy-rs against
iidy-hs. Previous "completion" declarations (Session 22) missed the entire output
pipeline. This phase exists to prevent that from happening again.

## Chunks

### 12.1: Command-by-Command Behavioral Parity Audit

For EVERY command, run both Rust and Haskell against the same input (mocked or
fixture) and diff the output. Document any divergences.

- [x] `render` — YAML preprocessing output (37/37 snapshots match)
- [x] `render --format json` — JSON output mode (fixed encodePretty, 12.1)
- [x] `render` error cases — enhanced error display (49/49 snapshots match)
- [x] `describe-stack` — event title format fixed (12.2), sections match, query flag matches
- [x] `list-stacks` — queryMode, tags, filter labels fixed (12.1)
- [x] `watch-stack` — mock polling tests, formatEvent, status detection (Phase 8.6)
- [x] `create-stack` — code review verified, flags match Rust
- [x] `update-stack` — --diff default fixed to true (12.2)
- [x] `create-or-update` — shares update-stack logic, verified
- [x] `delete-stack` — confirmation tests (Phase 8.6), flags match
- [x] `create-changeset` — flags match Rust, code review verified
- [x] `exec-changeset` — flags match Rust, code review verified
- [x] `get-stack-template` — format/stage flags match Rust
- [x] `describe-stack-drift` — drift-cache flag matches, code review verified
- [x] `estimate-cost` — code review verified
- [x] `lint-template` — code review verified
- [x] `convert-stack` — --sortkeys default fixed to true (12.2)
- [x] `init-stack-args` — verified identical file generation, force flags match
- [x] `template-approval-request` — --lint-template flag default matches
- [x] `template-approval-review` — --context flag matches
- [x] `explain` — 41 error codes match, more permissive input (documented)
- [x] `demo` — full implementation verified (shell, sleep, typing, masking)
- [x] `param get/set/get-by-path/get-history/review` — --decrypt default fixed (12.2), type default matches
- [x] `get-import` — format flag matches, code review verified
- [x] `completion` — $SHELL detection added (12.2), PowerShell omission documented
- [x] `--help` (global and per-command) — verified, documented framework differences

### 12.2: Output Mode Audit

- [x] Interactive mode (TTY): TTY check logic matches Rust
- [x] Plain mode (pipe/CI): same content, no ANSI, no spinners
- [x] JSON mode (`--output json`): JSON renderer tested (35 tests)
- [x] `--color=always` forces colors even in pipe
- [x] `--color=never` suppresses colors even on TTY
- [x] `--theme=dark/light/high-contrast` produce correct color codes (14 theme tests)
- [x] `NO_COLOR` env var respected (same priority as Rust)
- [x] `FORCE_COLOR` env var respected (both Rust and Haskell)

### 12.3: Error Handling Audit

- [x] YAML parse errors — enhanced display (49/49 error snapshots match)
- [x] YAML preprocess errors — all 6 error types verified
- [x] AWS operation errors — `dieTxt` format matches
- [x] Uncaught exceptions — `handleUncaughtException` format verified (Session 17)
- [x] Missing file errors — IO exception formatting verified
- [x] Invalid CLI args — optparse-applicative error format (documented divergence)
- [x] Stack not found — error message verified
- [x] Ctrl-C handling — _exit(130), no stack trace (Session 17)

### 12.4: Feature Completeness Checklist

Re-verify every item from the original workplan:

- [x] YAML 1.1 / 1.2 auto-detection and compatibility (Session 19)
- [x] All iidy tags: all 16 preprocessing tags verified present
- [x] CloudFormation intrinsics: all 18 intrinsic tags verified present
- [x] Import sources: file, env, SSM, CFN, Git, HTTP, S3, Random — all implemented
- [x] Handlebars: all block helpers + string/encoding helpers including toYaml, filehash, filehashBase64 (added 12.2)
- [x] JMESPath queries (custom ~600 LOC impl)
- [x] JSON Schema validation (custom Draft 7 ~170 LOC)
- [x] NTP time sync (custom SNTP client ~100 LOC)
- [x] Template hashing and S3 versioning
- [x] Demo command with playback (full implementation)
- [x] `explain` command with 41 error codes

### 12.5: Performance Comparison

- [x] Memory usage: 316 KB max residency, ~125 MiB total (Session 19)
- [x] Binary size: 12 MB (nix build, dynamically linked)
- [ ] Wall time comparison (requires complex real-world template)

### 12.6: Documentation of Known Divergences

Produce a final `DIVERGENCES.md` documenting every intentional difference:

- [x] CLI help formatting (clap vs optparse-applicative) — documented
- [x] serde_yaml snapshot format differences — documented
- [x] Shell completion (no PowerShell, $SHELL detection) — documented
- [x] Error color stderr vs stdout TTY check — documented
- [x] Explain command more permissive input — documented
- [x] AWS pagination untestable offline — documented
- [x] DIVERGENCES.md committed

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
