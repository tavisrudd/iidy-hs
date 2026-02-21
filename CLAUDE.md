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
- Try to keep modules under ~300-500 LOC; split if larger and possible

## Testing
- 100% tests pass on every commit. No exceptions.
- DO NOT reward hack by commenting out tests or fudging expected values
- Use `~/.claude/bin/run-quiet` for noisy test/build output
- All AWS testing uses mock fixtures. No real AWS calls.

## Git
- Green commits only: all tests pass + zero warnings
- Never create branches — all work on main
- Never reset/restore without backup and user confirmation
- `git config --local commit.gpgsign false` (YubiKey will hang otherwise)
- Run `git config --local commit.gpgsign false` if not already set before first commit

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

## Safety
- No destructive operations (rm -rf, git reset --hard, force push)
- No writing credentials, secrets, or API keys to disk
- No network calls except Hackage/nixpkgs downloads and ntfy notifications
