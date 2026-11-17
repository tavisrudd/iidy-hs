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

Landed and closed 2026-11-16: C5, C8, C9, C10, C11, C12, C13, C14, C15,
C16, C17, C24, C25, C26, C27, C28, C29, C31, C32, C33, C34, C36, C37, C38.

Paused by Tavis after C16 ("pause after c16"). Nothing is started; no
worker or worktree is live except the shared `review` worktree.

Ready to assign (decisions recorded on each card, 2026-11-16):
- C39 reject duplicate keys in templates and stack-args (Sonnet).
- C6 standalone reproducer of the shared-thunk hang and an upstream GHC
  report draft (Opus); evidence in `notes/C6/evidence-2026-11-16/`.
- C18 control-character escaping, C19 session-token redaction (security,
  Opus review), C20 resource limits, C21 hardening, C22 security docs and
  the `CommandsBefore` refusal, C30 explain/demo parity.
- C41 confirmation prompts decline on end of input (priority C).
- C40 implement `CommandsBefore` (priority C, design first).
File overlaps: C12-era `StackArgsLoader.hs` is shared by C22 and C39;
`Loaders/Http.hs` by C19, C20 and C21; `Demo.hs` by C21 and C30;
`DIVERGENCES.md` by most cards (append conflicts: keep both sides).

Waiting (parked): C6 (parked by Tavis 2026-11-17; remediation ideas on the card). C35 (emitter floats and
control characters) needs rescoping by Tavis.

## Decisions taken by Tavis on 2026-11-16 (recorded on the cards)

C16 region via `GetBucketLocation` with stack-region fallback (the
supervisor accepted fallback on any failure, reviewed as fail-closed);
C34 follow-up rejects duplicates at top level (C39); C6 option (a);
C18, C19, C20 (alias cap 250,000), C30 card proposals; C21 and C22 as
recommended.

## Still open for Tavis (supervisor's recommendation)

1. C17 (landed): computed credential fields refused only in files that
   make AWS imports (narrower than TypeScript): keep.
2. C20: the 250,000 alias cap does not reject the C4 review's example bomb
   (about 111,000 nodes, 253 MB): also cap expanded output size (about
   50 MB).
3. C39: demo scripts reject duplicate keys (yes); templates fetched by
   `convert-stack-to-iidy` stay lenient (yes, text comes from AWS).
4. C35 rescope, and the bug that iidy-hs drops `\x01` in YAML output.
5. Deploy-time lint (iidy-js lints at deploy; Rust and iidy-hs do not):
   file a low-priority card.

Answered by Tavis 2026-11-17: C16 accepted (approval changes apply only
with `ApprovedTemplateLocation` set). C20 adds an expanded-output size cap
of about 50 MB (recorded on the card). C39 as recommended (recorded on the
card). Deploy-time lint: no card; leaving it out is deliberate, because
iidy-js's lint rules went stale and caused problems. C17: keep the
narrower rule. C35 rescoped (non-printable strings double-quoted, blank-line
fix; floats dropped) and back to TODO. New Rust-side cards, which edit
`~/src/iidy` with Tavis's authorisation: C42 (Rust parser keeps `\x`, `\u`,
`\e` escapes as literal text; render quoting; after C35) and C43 (port the
C17 stack-args rule to Rust).
