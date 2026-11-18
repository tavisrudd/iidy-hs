# Supervisor handoff (iidy-hs) — updated 2026-11-17

## Mode

Tavis, 2026-11-16/17: Claude sub-agents only, no Codex panes, no mailbox:
sub-agents report in their final reply. Sonnet workers for ordinary cards,
Opus for design, refactor and security cards; an Opus reviewer resumed
with SendMessage between reviews, and a fresh one for a large or security
card. Brief template: `scripts/supervisor/CARD-BRIEF.md` (now says: run
builds and tests in the foreground, never detached).

## Rules that bite (all in RUNBOOK.md or PROTOCOL.md now)

- Never `rm` (Tavis). Read first; move to
  `.supervisor/trash/<date>/<card>/` with `mv`. Workers do the same.
- direnv only accepts the resolved path: use
  `/cache/tavis/iidy-hs/worktrees/<worker>` with `direnv exec`.
- Landing: `git merge --ff-only` (never piped through `tail`); otherwise
  replay with `git cherry-pick --no-commit SHA` + `git commit -C SHA`, one
  SHA per command or with an explicit `$?` check: `set -e` does not stop a
  loop in the Bash tool, and a failed commit was folded into the next one
  on 2026-11-17.
- A card whose earlier worktree record was released needs a fresh branch
  name to reassign (C35 used `claude/C35b`).
- Before `c set done`: check for an open `CLOCK:` line, unfinished task
  headings and unticked gate boxes (workers often leave them unticked).
- The memory guard refuses builds below 6 GiB available; since 2026-11-17
  it counts the reclaimable ZFS ARC (`scripts/avail-mem-kb`), which Tavis
  approved. Wait, never bypass.
- The C6 hang still happens: twice on 2026-11-17, in "directory hash is
  deterministic" and in "Demo / runDemo / a bash step runs" (both on C6).
  A commit failing with "build lock wait timed out" is usually one: find
  the long-running `iidy-hs-test` and kill it by PID.
- Claude sub-agents that detach a run (nohup/setsid) are never woken: a
  "waiting on its own background work" notification with no build running
  needs a SendMessage nudge.
- Parity rule (Tavis): Rust parity by default; where Rust and TypeScript
  disagree, Tavis chooses. His answers so far:
  `notes/C23/report--decisions-vs-originals.org` and the runbook.

## State at handoff

Landed and closed 2026-11-17 (second session): C30 (explain and demo
aligned with Rust, fractional demo sleep up to a day), C22 (security docs
corrected, `--debug` documented as no effect, hardening notes in
`docs/SECURITY.org`), C39 (repeated mapping keys rejected in templates,
stack-args and demo scripts, as ERR_1004), C40 (CommandsBefore runs under
Option E: iidy-js templates, every substituted value checked against a
safe character set, dry run before any command, `filehash` only as a whole
output). Earlier the same day: C18, C19, C20, C35.

Nothing started. Live worktree: the shared `review` worktree only. All
sub-agents of the session are finished.

Filed 2026-11-17: C42 to C48 (first session), C49 (demo `--timescaling`
bound), C50 (requirements docs name `.md` siblings), C51 (render's
parse-error display prints 0-based columns), C52 (`iidy_filehash` bash
helpers call `shasum -p`, which shasum 6.x rejects; parity question for
Tavis, recommendation: drop `-p`).

Still owed: C22's fold-in left C21's lines out of `docs/SECURITY.org`
(listed on C22); C21 adds them when it lands.

Next by `c next`: C44, C47, C21, C41, C42, then the rest by priority.
Parked: C6 (Tavis, 2026-11-17).

Small follow-ups noted, not filed: `test/Test/WatchStackTest.hs:363,376`
keeps its own Amazonka error builders (now in `Test.Shared`); residual
risk in `formatBuildException` if a future wrapper exception (e.g.
`ExceptionInLinkedThread`) carries an Amazonka error; no test drives
Runner's `--output-mode json` check for CommandsBefore (no test seam).

## Decisions by Tavis on 2026-11-17

C16 accepted. C17 narrower rule kept. C20 adds a 50 MiB expanded-size cap.
C39 demo strict, convert-stack lenient. Deploy-time lint stays out. C35
rescoped; floats dropped. C6 parked. The memory guard counts the
reclaimable ZFS ARC. AWS service errors print
`AWS <service> error <code>[: <message>] (HTTP <status>, request ID <id>)`.
C40: Option E (after Tavis named the kind of iidy-js file that must keep
working: imported values and `filehash` of a just-built file in a
command). Supervisor's calls are recorded on each card.

## Still open for Tavis (supervisor's recommendation)

1. C52: drop `-p` from the `iidy_filehash` bash helpers (a divergence from
   both originals, which share the bug), or keep Rust's text.
