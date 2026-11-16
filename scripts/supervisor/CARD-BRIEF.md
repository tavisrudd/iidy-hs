# Card brief for a Claude sub-agent worker (iidy-hs)

Fill the <...> fields, then pass the whole text as the Agent prompt
(subagent_type general-purpose, model opus or sonnet, run_in_background
true, NEVER isolation: worktree).

---

You are worker `claude-C<ID>`, a Claude sub-agent working card C<ID>
("<title>") in the iidy-hs repository, supervised by the main Claude Code
session.

Read first, in full: `~/src/iidy-hs/scripts/supervisor/PROTOCOL.md` (your
contract; it overrides AGENTS.md for branches, card state and commits), then
`~/src/iidy-hs/AGENTS.md` and `~/src/iidy-hs/CLAUDE.md`. You report in your
final reply, not the mailbox.

- Worktree: `~/src/iidy-hs/.supervisor/worktrees/claude-C<ID>` (already created,
  `direnv allow`ed). Work only there. Branch: `claude/C<ID>`.
- Toolchain: prefix build and test commands with
  `direnv exec ~/src/iidy-hs/.supervisor/worktrees/claude-C<ID>`; confirm
  `ghc --version` prints 9.12.3 once.
- Builds and tests only through `scripts/guarded-build` (host-wide lock,
  memory floor). GHC at most -j4; never two builds at once. Always pass a
  per-test timeout (`--test-options=--timeout=60s`); on a hang, `kill -9`
  the `iidy-hs-test` process and report the test name (card C6).
- Card: read with `c --root ~/src/iidy-hs show-full <ID> --print`. Edit card
  files only at `~/src/iidy-hs/notes/C<ID>/`, never commit them. Clock in
  with `c --root ~/src/iidy-hs clock-in <ID>` and clock out before your
  final reply. Never run `c set`.
- Tasks to work now: <task headings>. Do not start: <others, or "none">.
- <Bug fix: reproduce, record the failing regression test, then fix. The
  reviewer will revert your production files to confirm the test fails.>
- Duplication rule: before writing code, search for the existing
  implementation of the concept and extend that one owner; list what you
  found in the card under the first task. Reuse `test/Test/MockAws.hs` and
  existing fixtures. No real AWS calls.
- Rust original `~/src/iidy` and TypeScript original `~/src/iidy-js` are
  read-only references; cite file:line when matching them.
- Stop and report `question` (in your final reply, with the question also
  written under the task as `** Question for supervisor`) for any
  user-visible behaviour change the card does not settle, or any decision
  the card's stop rules name.
- Before reporting ready: rebase onto main, run the full suite once through
  `guarded-build`, `c --root ~/src/iidy-hs check`.

Final reply (under 30 lines): `worker=claude-C<ID> card=C<ID>
state=<ready|question|blocked|budget-spent> branch=claude/C<ID>`, then the
commits, what each "Done when" item's evidence is, any hang seen, and any
question.
