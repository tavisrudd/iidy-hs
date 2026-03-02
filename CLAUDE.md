# iidy-hs Project Instructions

## What This Is
Autonomous claude driven, Haskell port of iidy (a CloudFormation preprocessor/deployer). Porting from Rust (~/src/iidy/, read-only). See WORKPLAN.md for full plan.

## Coding Standards
- `-Wall -Wcompat` clean, zero warnings
- Explicit type signatures on all top-level bindings
- Prefer `Text` over `String`
- Use qualified imports for amazonka, aeson, containers
- No orphan instances
- No partial functions (head, tail, fromJust, etc.)
- Always `import qualified Data.List as List` and use `List.foldl'` — GHC 9.6 doesn't re-export `foldl'` from Prelude (9.10+ does), and an unqualified `import Data.List (foldl')` triggers `-Wunused-imports` on 9.10. The qualified import works on both.
- Try to keep modules under ~300-500 LOC; split if larger and possible

## Testing
- 100% tests pass on every commit. No exceptions.
- DO NOT reward hack by commenting out tests or fudging expected values. 
- Structure the test modules, groups and fixtures for maintainabililty
  and readability. No monolothic & massive test/Main.hs, etc.
- Use `~/.claude/bin/run-quiet` for noisy test/build output
- All AWS testing uses mock fixtures. No real AWS calls.

## Git
- Green commits only: all tests pass + zero warnings
- Never create branches — all work on main
- Never reset/restore without backup and user confirmation
- `git config --local commit.gpgsign false` (YubiKey will hang otherwise)
- Run `git config --local commit.gpgsign false` if not already set before first commit
- **Never use bare `git cherry-pick`.** It bypasses pre-commit hooks. Always use `git cherry-pick --no-commit` then `git commit` so hooks run.

## Build
- `cabal build` for compilation, in nix direnv / dev shell
- `cabal jobs: 4`, `-O0` for dev builds
- Use `~/.claude/bin/run-quiet` wrapper for builds to avoid flooding context

## Anti-patterns
- No duplicate code — extract shared logic
- No placeholder/stub implementations left uncommitted
- No `undefined` or `error "TODO"` in committed code
- No unnecessary dependencies
- No modifications to files outside ~/src/iidy-hs/
- Read-only access to ~/src/iidy/

## Progress Logging
- After completing each workplan chunk (2.1, 2.2, etc.), append a timestamped line to `progress.log`
- Format: `YYYY-MM-DD HH:MM — Chunk X.Y: <brief description of what was done>`
- Also log gate pass/fail results
- APPEND lines only (use Edit tool to add at end) — never rewrite/recreate the file
- This file is for `tail -f` monitoring — keep entries single-line

## Safety
- No destructive operations (rm -rf, git reset --hard, force push)
- No writing credentials, secrets, or API keys to disk
- No network calls except Hackage/nixpkgs downloads and ntfy notifications

## Feature Completeness
- This is a COMPLETE port. Every Rust feature gets ported. No shortcuts, no dropping features.
- NTP time sync, full schema validation, demo command — everything.
- No "minimal subset", no "deferred indefinitely", no "marginal value" judgments.
- If Rust has it, Haskell gets it.

## End-of-Session Gate (every session, non-negotiable)
Before wrapping up, verify ALL of these:
- WORKPLAN.md phase index is current (status, links)
- Current phase doc checkboxes reflect actual state
- Session handoff doc created in notes/sessions/ with: what done, deviations, next steps
- progress.log has entries for all completed chunks
- MEMORY.md reflects any new learnings or status changes
- All doc updates committed alongside code
- No orphaned TODOs — anything deferred is tracked in a phase doc

## Research Before Implementation
- Each phase MUST begin with a research cycle before any code is written.
- Research goes INTO the phase doc (e.g. `notes/phases/phase-7-error-display.md`) and is committed.
- Research includes: Rust source code pointers, sample snippets, key function signatures, data flow analysis.
- Do NOT rely on context window or external memory files for code research — put it in committed files under `notes/`.
- If memory files contain detailed code research, move that content into `notes/` files and commit them.
- Do NOT begin implementing until the phase doc has the research section filled in.

## Session Size & Delegation
- Keep sessions SHORT. Each session = 1-2 good green commits, then exit.
- If a subphase is too large for 1-2 commits, split it across sessions.
- Exit cleanly so the ralph loop continues with fresh context.
- Don't try to do everything in one session. Small, focused, done.
- Use sub-agents (Task tool) for research, exploration, and parallel work to keep main context clean.
- Delegate to Sonnet sub-agents for straightforward implementation after Opus designs the interface.
- Use Explore agents for codebase searches rather than flooding main context with grep results.

## Ralph?
If you are running in headless -p mode read @RALPH.md and check ./.msgs/ frequently.
