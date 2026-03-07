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
- **Never use bare `git cherry-pick`.** It bypasses pre-commit hooks. Always use `git cherry-pick --no-commit`, then `git commit -C CHERRY_PICK_HEAD` to reuse the original commit message while running hooks.

## Build
- `make build` for compilation, in nix direnv / dev shell
- Use `~/.claude/bin/run-quiet` wrapper for builds to avoid flooding context
- **When adding a new Haskell dependency**: add it to BOTH `iidy-hs.cabal` (build-depends) AND `flake.nix` (haskellDeps list). Missing either causes build failures in different environments.

## Anti-patterns
- No duplicate code — extract shared logic
- No placeholder/stub implementations left uncommitted
- No `undefined` or `error "TODO"` in committed code
- No unnecessary dependencies
- No modifications to files outside ~/src/iidy-hs/
- Read-only access to ~/src/iidy/

## Progress Logging
- Append a timestamped line to `progress.log` after completing work
- Format: `YYYY-MM-DD HH:MM — $CLAUDE_SESSION_NUM ($CLAUDE_SESSION_ID): <brief description>`
- Session number format: `YYYY-MM-DD--N` (daily counter, e.g. `2026-03-02--3`)
- Both env vars set by SessionStart hook. UUID is canonical, number is shorthand.
- APPEND lines only (use Edit tool to add at end) — never rewrite/recreate the file
- This file is for `tail -f` monitoring — keep entries single-line

## Safety
- No destructive operations (rm -rf, git reset --hard, force push)
- No writing credentials, secrets, or API keys to disk
- No network calls except Hackage/nixpkgs downloads and ntfy notifications


## Research Before Implementation
- Each phase MUST begin with a research cycle before any code is written.
- Research goes INTO the phase doc (e.g. `notes/phases/phase-7-error-display.md`) and is committed.
- Research includes: Rust source code pointers, sample snippets, key function signatures, data flow analysis.
- Do NOT rely on context window or external memory files for code research — put it in committed files under `notes/`.
- If memory files contain detailed code research, move that content into `notes/` files and commit them.
- Do NOT begin implementing until the phase doc has the research section filled in.

## Sub-Agent Git Rules
- **Main agent owns the commit sequence.** Only the main agent does cherry-picks, merges, rebases, pushes.
- Sub-agents doing direct coding on main: may `git add` + `git commit` for their specific files only.
- Sub-agents doing research on main: NO git write operations at all.

## Parallel Sub-Agents and Worktrees

### DO NOT use `isolation: worktree` on the Agent tool
The `isolation: worktree` parameter auto-cherry-picks sub-agent commits to main and deletes the worktree on exit. This bypasses main-agent review and pre-commit hooks. **Never use it.**

### Option A: Regular parallel agents (preferred for non-overlapping files)
When parallel sub-agents edit **different files**, just launch them without worktree isolation. Each agent edits its own files directly on main. The main agent reviews and commits (or the sub-agents commit their own files).
```
Agent(subagent_type=general-purpose, prompt="Edit src/Foo.hs ... then git add src/Foo.hs && git commit ...")
Agent(subagent_type=general-purpose, prompt="Edit src/Bar.hs ... then git add src/Bar.hs && git commit ...")
```

### Option B: Manual worktrees (for overlapping files)
When parallel sub-agents might edit the **same files**, create manual worktrees:
```bash
git worktree add .worktrees/task-a -b task-a
git worktree add .worktrees/task-b -b task-b
```
Then launch agents with cwd in the worktree. Main agent cherry-picks after review:
```bash
git cherry-pick --no-commit task-a
git commit -C CHERRY_PICK_HEAD
git worktree remove .worktrees/task-a
git branch -d task-a
```

### Hooks (still active for manual worktrees)
- **PreToolUse hook** (`scripts/enforce-worktree-isolation.sh`) blocks writes outside worktree when cwd is in `.claude/worktrees/` or `.worktrees/`.
- **WorktreeCreate hook** (`scripts/worktree-setup.sh`) sets `core.hooksPath=.githooks` and `commit.gpgsign=false`.
- Pre-commit hooks run in worktrees via shared `core.hooksPath=.githooks`.

## Ralph?
If you are running in headless -p mode read RALPH.md.
