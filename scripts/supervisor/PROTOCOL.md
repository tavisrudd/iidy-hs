# Supervised worker protocol (iidy-hs)

You are a worker (a Codex session in a tmux pane, or a Claude sub-agent)
supervised by a Claude Code session (the supervisor) acting for Tavis. Read
this file completely before starting, then `AGENTS.md` and `CLAUDE.md`.
Re-read this file after any context compaction.

Where this file and `AGENTS.md` or `CLAUDE.md` disagree, this file wins for
supervised work. In particular: you work on a card branch in your own
worktree (not on `main`), and card state (`c set`) belongs to the
supervisor.

## Your identity and workspace

- Your worker name is given in your first instruction, for example
  `codex-1` or `claude-C14`.
- You work only in your own worktree: `~/.cache/iidy-hs/worktrees/<worker>`,
  on branch `<worker-prefix>/C<ID>` (for example `codex/codex-1/C14` or
  `claude/C14`) for the current card. The supervisor creates the worktree
  and branches. You never touch `main`, never run `git push`, never merge,
  never rebase onto or reset branches you did not create, never use
  `git stash` (the stash is shared across worktrees; use a WIP commit), and
  never delete worktrees, branches or cache.
- Toolchain: run every build and test command inside the project's Nix dev
  shell for your worktree: prefix commands with
  `direnv exec ~/.cache/iidy-hs/worktrees/<worker>` (the supervisor has run
  `direnv allow` there). Confirm once that `ghc --version` prints the version
  the dev shell pins (9.12.3 since card C3); a bare shell may find an older
  GHC.
- Build and test only through `scripts/guarded-build` (from your worktree).
  It holds the host-wide build lock, refuses to start when memory is low,
  and runs under `choom`. Never run bare `cabal`, `make build` or
  `nix build`; wrap them. The pre-commit hook takes the same lock itself.
  Build output stays in your worktree's `dist-newstyle/`.
- Memory is shared with other heavy work on this host. Never pass GHC more
  than `-j4`; run Nix with `--max-jobs 1 --cores 4`; start no second build
  or test run while one is running.

## Where things go

- Card bookkeeping lives on the main checkout so status stays visible: run
  every `c` command with `--root ~/src/iidy-hs`, and edit your card's files
  (`index.org`, `report--*.org`, `scratch.org`) at
  `~/src/iidy-hs/notes/C<ID>/` directly. Never commit in `~/src/iidy-hs`;
  the supervisor commits card changes when it lands your work. Touch only
  your own card's files there. Never commit card files on your branch.
- Source, tests, fixtures, scripts and docs change only in your worktree,
  committed on your branch.
- Ignore the copy of `notes/` inside your worktree; it goes stale.

## Working a card

1. The supervisor assigns one card (or named tasks of it) at a time and has
   already started it on `main`. Load it with `c --root ~/src/iidy-hs <ID>`,
   read it in full with `c --root ~/src/iidy-hs show-full <ID> --print`,
   and read its linked context.
2. Run `c --root ~/src/iidy-hs clock-in <ID>` when you start and
   `clock-out <ID>` whenever you stop, pause for review, or hand back.
3. Work the open TODO headings in order. The card's Scope and gate is
   binding: "Allowed paths", "Out of scope", "Done when" and "Stop and
   record if" where the card has them, otherwise its allowed paths and
   gate prose.
   - Change nothing outside the allowed paths. A module's test module and
     fixtures are inside the allowed paths whenever the module is, and so are
     the `other-modules` lists in `iidy-hs.cabal` for modules you add.
   - A task is finished only when its "Done when" items hold; tick each
     checkbox in the card as it becomes true.
   - When a "Stop and record if" condition occurs, write what you found under
     the task and report `budget-spent` or `question`. Do not work around it.
   - If a task states no budget, its budget is two distinct approaches or
     about two hours of work without meeting its "Done when" items. Spending
     the budget is a finished result: record it and report `budget-spent`.
   - Do not start the next task, add experiments or widen scope without the
     supervisor's word.
4. For a bug fix: reproduce first, record the failing regression test on the
   branch base, then fix. A regression test that passes without the fix is a
   defect.
5. Commit small, green, reviewable commits: one fix per commit, a plain
   message naming the card (`C<ID>: <summary>`), no co-author or attribution
   lines, explicit paths only. Commits are unsigned (the worktree inherits
   `commit.gpgsign false`). The pre-commit hook runs fourmolu, hlint, the
   dependency check, a `-Werror` build and the full test suite under the
   build lock; never bypass it (`--no-verify` and `SKIP_TESTS=1` are
   forbidden on commits that touch code). Before committing, run the
   focused tests for what you changed:

       scripts/guarded-build cabal test all --test-show-details=direct \
         --test-options='--timeout=60s -p "<pattern>"'

   Never commit after a failing run. Codex workers: run long commands
   detached (`nohup setsid ... > LOG 2>&1 &`) and poll the log if your shell
   tool has a short timeout. Claude sub-agents: never detach; run builds,
   tests and commits in the foreground with a long Bash tool timeout (up to
   600000 ms), and wrap test runs in `timeout -s KILL 600`. A detached job
   is invisible to a sub-agent's harness, so the sub-agent is never woken
   when it ends. A command killed while it waits on the build lock is not a
   failure.
6. Known flaky hang (card C6): a test can hang forever and ignore SIGTERM.
   Always pass a per-test timeout. If a run or a commit hangs, `kill -9` the
   `iidy-hs-test` process from your worktree (by PID, after checking its
   path; never `pkill -f`, which kills other workers' runs), note the test
   name (if a timeout named it) in your report, and retry once.
7. Mark a task heading done with
   `c --root ~/src/iidy-hs todo ~/src/iidy-hs/notes/C<ID>/index.org <HEADING-ID> DONE`
   only when its "Done when" items hold. Never run `c set`; card state
   belongs to the supervisor.
8. If the card is wrong, ambiguous, or needs a decision from Tavis, stop and
   report `question` instead of guessing.
9. Org you write in cards: wrap prose at 80 columns, keep each link
   `[[target][description]]` on one line, and write results under the task
   heading they belong to. Run `c --root ~/src/iidy-hs stamp FILE` after
   adding headings and `c --root ~/src/iidy-hs check` before reporting.

## Code rules you will trip on

`CLAUDE.md` has all of them; these are the ones agents most often miss:
- `-Wall -Wcompat` clean; explicit type signatures on all top-level
  bindings; `Text` over `String`; qualified imports for amazonka, aeson and
  containers; `import qualified Data.List as List` and `List.foldl'`.
- No partial functions (`head`, `tail`, `fromJust`, ...), no orphan
  instances, no `undefined` or `error "TODO"`.
- No duplicate code: find the existing implementation by searching for the
  concept and extend that one owner. Extend an existing test fixture or
  helper (for example `test/Test/MockAws.hs`) instead of repeating setup.
- Modules stay under about 500 lines; split rather than grow past it.
- A new dependency goes in both `iidy-hs.cabal` and `flake.nix`, and only
  when the card allows it.
- Tests are structured per module; no real AWS calls, ever (mock fixtures
  only); tests must fail on broken code.
- Behaviour that differs from the Rust original (`~/src/iidy`, read-only) is
  a defect unless the card or `DIVERGENCES.md` says otherwise; cite the Rust
  file and line when you match it.

## Reporting to the supervisor

Codex workers append exactly one line to the mailbox with a single shell
command, so the write is atomic:

    printf '%s worker=%s card=C%s state=%s branch=%s msg=%s\n' \
      "$(date -Is)" codex-1 14 ready "codex/codex-1/C14" \
      "one-line summary" >> ~/src/iidy-hs/.supervisor/mailbox.log

Claude sub-agents report the same fields in their final reply instead.

- `state` is one of:
  - `ready`: a task or the whole card is ready for review; commits are on the
    branch and every check passes.
  - `question`: you need a decision; write it in the card under a
    `** Question for supervisor` child of the current task, then report.
  - `blocked`: an external failure (tool, build, environment) stops you;
    describe it in the card's `scratch.org` and report.
  - `budget-spent`: a stop rule or budget ended the task without meeting its
    "Done when" items; the card records the finite result.
- Before reporting `ready`, rebase your branch onto current `main`
  (`git rebase main` in your worktree; the branch is yours) and rerun the
  full suite once on the rebased tip, so the supervisor can land by
  fast-forward and the commit IDs you cite stay valid. If the rebase
  conflicts outside your card's paths, report `question` instead.
- Attribute decisions correctly in the card: a decision from the supervisor
  is the supervisor's; write "Tavis" only for Tavis's own recorded decisions.
- Keep `msg` to one line under about 200 characters; details go in the card.
  Never write anything else to the mailbox, and never edit or truncate it.
- After reporting, clock out, stop editing your card's files on the main
  checkout, and wait. Do nothing further until the supervisor writes to you.

## Receiving feedback

The supervisor answers in your pane (or by message), or adds a
`** Review feedback <date>` child heading under the relevant task in your
card. Review feedback is binding: fix exactly what it asks, commit, and
report `ready` again. If feedback conflicts with `CLAUDE.md` or the card's
gate, report `question` rather than choosing.

## Cleanup

- Make temporary directories only with
  `mktemp -d ~/src/iidy-hs/.supervisor/tmp/<worker>.XXXXXX`, never in `/tmp` or a
  shared location. Record each one in your card's `scratch.org` under a
  `Cache artifacts` heading as you go.
- When you report a task `ready`, clear the temporary directories you made
  for it without deleting anything: `mkdir -p
  ~/src/iidy-hs/.supervisor/trash/<YYYY-MM-DD>/<worker>` and `mv` each
  directory there by its literal absolute path. Never run `rm` (Tavis empties
  the trash), and never on a path built from a variable or glob. Put any
  temporary file inside your own `mktemp` directory, not loose in
  `.supervisor/tmp/`.
- Never delete shared cache, other workers' files, worktrees or branches.

## Hard limits

- No `git push`, no merging into `main`, no history rewriting of shared refs,
  no `git stash`.
- No `c set`; no installs into Tavis's profile.
- No real AWS calls and no network beyond Nix and Hackage downloads.
- No deletion of cache, worktrees, evidence or other people's files.
- No new dependencies or user-facing behaviour beyond what the card allows.
- No changes to `~/src/iidy` (read-only) or any repository other than your
  worktree and your own card's files on the main checkout.
- Never use the words "honest", "honestly" or "honesty" in any text.
