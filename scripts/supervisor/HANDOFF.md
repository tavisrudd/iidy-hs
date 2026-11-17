# Supervisor handoff (iidy-hs) — written 2026-11-16 by the first supervised session

## Mode

Tavis, 2026-11-16: Claude sub-agents only (Opus for security, design and
refactor cards and their reviews; Sonnet for bounded fixes, tests, docs,
card refinement and their reviews). No Codex panes, no mailbox: sub-agents
report in their final reply and are steered with SendMessage. Brief
template: `scripts/supervisor/CARD-BRIEF.md`; the briefs used today (in
this session's transcript) add the rules below.

## Rules that bite (all in RUNBOOK.md or PROTOCOL.md now)

- Never `rm` (Tavis). Read first; move to
  `.supervisor/trash/<date>/<card>/` with `mv`. Workers do the same.
- direnv only accepts the resolved path: use
  `/cache/tavis/iidy-hs/worktrees/<worker>` with `direnv exec`.
- Landing: `git merge --ff-only` (never piped through `tail`); otherwise
  replay with `git cherry-pick --no-commit SHA` + `git commit -C SHA` (a
  single-commit pick leaves no `CHERRY_PICK_HEAD`). On a conflict, undo only
  the pick's code paths and have the worker rebase; `rerere` is on and its
  cache is shared by all worktrees.
- Before `c set done`: check for an open `CLOCK:` line and unfinished task
  headings; resume the worker to clock out (a `C_SESSION_ID` override does
  not accept sub-agent IDs).
- The memory guard refuses builds below 6 GiB; another project (peregrine)
  on this host sometimes runs big Rust builds. Wait, never bypass.
- Workers kill hung tests by PID only (one used `pkill -f`); never
  `--no-verify` (one amended with it during a rebase).
- Parity rule (Tavis): Rust parity by default; where Rust and TypeScript
  disagree, Tavis chooses. His answers so far:
  `notes/C23/report--decisions-vs-originals.org` and the runbook.

## State at handoff

Landed and closed today: C5, C8, C9, C10, C11, C13, C14, C15, C17, C24,
C25, C26, C27, C28, C29, C31, C33, C34, C36, C37.

In flight:
- C12 landed and closed (loader split; C17 backstop wiring tested).
- C32 (Sonnet, `claude/C32`): keep the written `!$` tag spelling for
  unresolved-tag output; may first split Parser.hs (550 lines). Review with
  Sonnet before landing.
- C38 landed and closed. C21 and C22 are refined; tasks that depend on
  Tavis's answers are marked "do not start before" them.
- C16 (Opus worker, `claude/C16` worktree; tasks 1-3, round 2 and its fix
  round landed). Stopped before "Approval bucket region has one owner";
  remaining: region, presign, deploy builders, estimate-cost, empty-diff
  prompt, docs. Resume the same worker (its brief and card notes have the
  plan) once Tavis answers the region question.

Waiting (parked):
- C6 test-suite hang: second budget reproduced 3 hangs under load in the
  TemplateLoader group; thread dump shows test threads blocked on a shared
  thunk, masked; suspects the GHC RTS. Evidence in
  `notes/C6/evidence-2026-11-16/`. Needs Tavis's choice.
- C35 emitter floats and control characters: needs rescoping (floats need
  a number-representation change; Rust's targets differ by command).

TODO with no blocker: C12, C21, C22 (after refinement), C32 (priority C).

## Decisions waiting on Tavis (with the supervisor's recommendation)

1. C16 approval bucket region: ask S3 (`GetBucketLocation`), falling back
   to the stack's region.
2. C17 (landed): computed credential fields refused only in files that
   make AWS imports (narrower than TypeScript): keep.
3. C34 follow-up: top-level templates and stack-args also reject duplicate
   keys (TypeScript) rather than accept them (Rust): reject; it is a
   one-flag change (`parseYamlStrict`).
4. C6 next step: (a) standalone reproducer and upstream report.
5. C18 escaping, C19 error wording, C20 limit values (alias cap 250,000
   rather than 1,000,000), `!$toYamlString` trailing newline (keep Rust's
   strip, record the TypeScript difference): accept the card proposals.
6. C30: keep iidy-hs's `explain` layout; keep demo sleep rounding.
7. Deploy-time lint (iidy-js lints at deploy; Rust and iidy-hs do not):
   file a low-priority card.
8. C35 rescope, and the plain bug that iidy-hs drops `\x01` in YAML
   output.
9. C22 `CommandsBefore` (Rust and TypeScript run it through bash; iidy-hs
   skips it silently): reject it with a clear error now, and file a card
   for implementing it with its own trust design. `--debug`: keep it
   accepted and document it as having no effect.
10. C21: NTP answers more than five minutes from the system clock are
    rejected and NTP is skipped under `--no-remote-imports`; convert-stack
    refuses to overwrite files without a new `--force`; plaintext `http:`
    stays accepted, an https-to-http redirect is refused, no digest
    pinning. Recommend yes to each.
