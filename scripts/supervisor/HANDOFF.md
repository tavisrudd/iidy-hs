# Supervisor handoff (iidy-hs) — updated 2026-11-17

## Mode

Tavis, 2026-11-16/17: Claude sub-agents only. On 2026-11-17 Tavis asked for
Sonnet workers on the cards and a single Opus reviewer for all of them,
reviewing one card at a time and resumed with SendMessage between reviews.
No Codex panes, no mailbox: sub-agents report in their final reply. Brief
template: `scripts/supervisor/CARD-BRIEF.md`.

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
- The C6 hang still happens: 2026-11-17 a run stuck at "directory hash is
  deterministic", outside the TemplateLoader group (recorded on C6).
- Parity rule (Tavis): Rust parity by default; where Rust and TypeScript
  disagree, Tavis chooses. His answers so far:
  `notes/C23/report--decisions-vs-originals.org` and the runbook.

## State at handoff

Landed and closed 2026-11-17: C18 (terminal control-character escaping),
C19 (AWS/HTTP errors without requests or credentials), C20 (resource
limits), C35 (YAML emitter escapes non-printable characters).

Nothing started. Live worktree: the shared `review` worktree only. The
Opus reviewer and the Sonnet workers of 2026-11-17 are finished (idle).

Filed 2026-11-17: C42 (Rust: decode all YAML escapes, render quoting;
unblocked now C35 landed), C43 (Rust: port C17's stack-args rule), C44
(`$defs` amplification limit, priority B), C45 (`replace` with an empty
search string crashes), C46 (import parse errors print `show` output),
C47 (escape error text printed outside the renderer, priority B), C48
(bind template approval to the hash the reviewer saw; design for Tavis
first). C42 and C43 edit `~/src/iidy` with Tavis's authorisation.

Next by `c next`: C22 (security docs, now also C20's limits), C30, then
the cards above by priority. Parked: C6 (Tavis, 2026-11-17).

Small follow-ups noted, not filed: `test/Test/WatchStackTest.hs:363,376`
keeps its own Amazonka error builders (now in `Test.Shared`); residual
risk in `formatBuildException` if a future wrapper exception (e.g.
`ExceptionInLinkedThread`) carries an Amazonka error.

## Decisions by Tavis on 2026-11-17

C16 accepted. C17 narrower rule kept. C20 adds a 50 MiB expanded-size cap
(the C4 bomb turned out to exceed the node cap anyway). C39 demo strict,
convert-stack lenient. Deploy-time lint stays out (deliberate). C35
rescoped; floats dropped. C6 parked. Supervisor's calls recorded on the
cards: C19 scope widened (S3Objects, LazyEnv, StackArgsBootstrap), S3
errors keep `HTTP <status>: `; C35 scope widened to ConvertStack escaping,
convert-stack keeps its own when-to-quote policy.

## Still open for Tavis (supervisor's recommendation)

1. C19: a `ServiceError` with no message prints the code alone
   (`InternalFailure`, not `InternalFailure: `): keep (landed that way).
