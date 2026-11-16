# Supervisor runbook (iidy-hs)

How the Claude Code supervisor runs workers on iidy-hs cards. Workers are
Codex sessions in tmux panes or Claude sub-agents; both follow `PROTOCOL.md`
in this directory, and the review worker follows `REVIEW.md`. This file is
the supervisor's side. Tavis does not run workers unsupervised: they are
productive but widen scope and need review before anything lands. The
supervisor assigns, reviews, lands and cleans up.

Ported from peregrine's `scripts/supervisor/` (card C23). Peregrine-specific
material (benchmarks, quiet-host windows, terminal UI checks, deploys, the
refinement merge script) was left out; add it here when this project needs
it.

## Files

`~/.cache` is ephemeral on this host (Tavis, 2026-11-16): nothing the
supervision needs to keep lives there. Worker worktrees are the one
exception (Tavis, 2026-11-16), because they are disposable once their work
is committed.

- Tracked, in `scripts/supervisor/`: `PROTOCOL.md` (the worker contract),
  `RUNBOOK.md` (this file), `REVIEW.md` (the review worker's brief),
  `CARD-BRIEF.md` (the template for a Claude sub-agent's brief),
  `HANDOFF.md` (the in-flight picture for the next supervisor session:
  workers, cards, open decisions; rewrite and commit it before a session
  ends), `send.sh` (paste a message into a Codex pane) and `status.sh` (one
  line per worker). The build lock is `scripts/guarded-build`; the
  pre-commit hook takes it too.
- Runtime, untracked (git-ignored), in `~/src/iidy-hs/.supervisor/`:
  - `mailbox.log`: one line per Codex worker report (format in
    `PROTOCOL.md`).
  - `panes.txt`: `codex-1=%ID codex-2=%ID review=%ID` on one line.
  - `msg-*.txt`, `assign-*.txt`: messages written before sending.
  - `build.lock`: the lock file `guarded-build` holds.
  - `tmp/`: workers' temporary directories.
- Worker worktrees, in `~/.cache/iidy-hs/worktrees/<worker>`: one per
  worker (`codex-<n>`, `review`, or `claude-C<ID>` for a sub-agent), each
  with its own `dist-newstyle/`. Commits live in the main repository; only
  uncommitted edits are in the worktree, so workers make WIP commits before
  pausing. If the cache is wiped, run `git worktree prune`, then recreate
  the worktree on its branch (`git worktree add WT <branch>`) and
  `direnv allow` it. They are not
  under the repo's `.worktrees/`, which the worktree-isolation hook guards:
  it would block workers from editing their card on the main checkout.

## Setup (once per worker)

1. `mkdir -p ~/src/iidy-hs/.supervisor/tmp ~/.cache/iidy-hs/worktrees`
   and create an empty `~/src/iidy-hs/.supervisor/mailbox.log`.
2. From `~/src/iidy-hs`:
   `git worktree add ~/.cache/iidy-hs/worktrees/<worker> -b <branch> main`
   (branch `codex/codex-<n>/C<ID>` or `claude/C<ID>`; the review worktree
   is detached: `git worktree add --detach ~/.cache/iidy-hs/worktrees/review main`).
3. `direnv allow ~/.cache/iidy-hs/worktrees/<worker>` so the worker can run
   `direnv exec` there. The first build in a fresh worktree compiles the
   whole project; the Haskell dependencies come from the Nix store.
4. Codex workers: in Tavis's tmux, a window `iidy:codex` with one pane per
   worker, cwd the worker's worktree, running Codex (models below). Record
   the pane IDs in `panes.txt`. Ask Tavis before launching Codex panes.
5. Claude sub-agents: launch with the Agent tool (never
   `isolation: worktree`, per `CLAUDE.md`), cwd the worktree, with a brief
   that names `PROTOCOL.md` to read first, the worker name, worktree,
   branch, card and tasks, and that it reports in its final reply instead of
   the mailbox.
6. To restart a Codex pane, send `C-c` twice (`/quit` alone is unreliable),
   check with `pstree -p $(tmux display -p -t PANE '#{pane_pid}')` that codex
   is gone, launch the new command, then send a short brief that names
   `PROTOCOL.md` (or `REVIEW.md`) to read first.

## Choosing and preparing cards

- Order comes from `c next` (priority, then ID) and respects `c deps`.
- WIP cap: two coding workers plus one review worker (supervisor's default,
  2026-11-16, set by the memory limits on this host; Tavis may change it).
  Close out started cards before starting new ones. Skip cards whose
  allowed paths overlap a card in flight.
- Cards that start with a discussion with Tavis (C15 and C16 at the time of
  writing) are not assigned past that task until he has decided.
- Before assigning, make sure the card is fit for a worker. Its Scope and
  gate has labelled paragraphs:
  - `Allowed paths:` the files and directories the work may change;
  - `Out of scope:` what it must not do;
  - `Done when:` a checklist (`- [ ]`) of evidence, including the tests;
  - `Stop and record if:` conditions that end the task early;
  and its tasks are small, ordered TODO headings. Cards filed before C23
  have allowed paths and gate prose only: refine them on `main` first
  (directly, or by a research worker with a per-batch exception to edit
  named cards), then `c stamp`, `c check` and commit.

## Assigning

1. On `main`: `c set <ID> started`, then commit the card file and the lane
   links (stage those paths explicitly), and
   `c worktree assign <ID> --path WT`.
2. In the worker's worktree, after its previous branch landed:
   `git -C WT switch -c <branch> main`.
3. Codex: write the assignment to `assign-<worker>.txt` and send it with
   `scripts/supervisor/send.sh PANE FILE`. Sub-agent: put the same text in
   its brief. It names: the worker, the protocol path
   (`~/src/iidy-hs/scripts/supervisor/PROTOCOL.md`, read in full first), the
   worktree and branch, the card, the exact tasks to work (and the ones not
   to start), the duplication rule (find the existing owner by concept search
   and extend it), "reproduce, record the failing regression, then fix" for
   bug fixes, and a reminder that the card's stop rules are binding.

- A worker whose branch is in review may start its next card: its branch is
  committed and clean, so it switches to a new branch from main, and switches
  back (after a WIP commit) if a fix round arrives. `c worktree assign` for
  the new card fails until the old record is completed and integrated.

## Monitoring

- Watch the mailbox with the Monitor tool:
  `tail -n0 -F ~/src/iidy-hs/.supervisor/mailbox.log 2>/dev/null | grep --line-buffered -E 'worker='`
  at the maximum timeout; re-arm on every expiry and run `status.sh` then.
  After each re-arm, `tail -3` the mailbox and handle any unanswered line.
- `status.sh` prints one line per worker (pane alive, BUSY or IDLE, branch
  ahead and behind, dirty files, last mailbox line), one line per sub-agent
  worktree, then dirty card notes on main, whether the build lock is held,
  running GHC processes, available memory and load. `-v` adds recent
  activity. Capture a pane (`tmux capture-pane -p -t PANE -S -60`) only to
  answer a specific question.
- Keep monitoring cheap: act on mailbox events and sub-agent notifications,
  keep replies to Tavis short.
- A message pasted into a busy Codex pane waits until its turn ends; for an
  urgent stop send `tmux send-keys -t PANE Escape` first.
- Builds queue on the build lock; several workers building at once is slow,
  not dangerous. Swap is zram: judge memory by MemAvailable and pressure,
  not the swap total.

## Handling reports

- `question`: read the question in the card, decide if it is within the
  card's scope and the recorded decisions; otherwise bring it to Tavis with a
  recommendation. Answer in the pane or with SendMessage.
- `blocked`: read `scratch.org`, fix the environment or reassign.
- `budget-spent`: accept the finite result; decide whether the card closes,
  goes WAITING with a note, or gets a new, narrower card. A WAITING card
  whose partial work landed frees its worktree with
  `c worktree release <ID> --commit <main sha> --note ...`.
- `ready`: review, then land or send one numbered fix round.

## Reviewing

- The deep code review goes to the review worker per `REVIEW.md`: send it
  the card, branch, base and gate items; it writes a `** Review <date>`
  heading in the card and reports `review:`. The supervisor does not repeat
  that line-by-line review.
- The supervisor reviews at the high level: scope and allowed paths, the
  design against `CLAUDE.md` and recorded decisions, whether the reviewer's
  findings are real and in scope, the gate evidence (not the worker's
  summary), and the workflow (card state, commits, landing, cleanup).
- Send defects back as one numbered fix round, or as a
  `** Review feedback <date>` heading under the task.
- Script-only, test-only and narrow single-function fixes may land on the
  supervisor's own diff check without the review worker; say so in the close
  note. A fix round that changes production code goes back to the review
  worker for a narrow re-review of just the findings.
- Security cards (the C4 follow-ups) always go to the review worker.

## Landing

1. On `main` in `~/src/iidy-hs`: `git merge --ff-only <branch>` (workers
   rebase before reporting `ready`, and the hook ran the full suite on each
   commit). If main moved, ask the worker to rebase and rerun the suite
   rather than merging.
2. If a fast-forward is impossible and main moved only by notes commits,
   replay the branch per `CLAUDE.md` (never a bare cherry-pick): for each
   commit, `git cherry-pick --no-commit SHA` then
   `git commit -C CHERRY_PICK_HEAD`, so the hook runs. Stop at the first
   failure (`git cherry-pick --abort`) and never run the close steps after
   a failed pick.
3. Close the card on main, in this order: the worker's clock closed (resume
   a sub-agent to run `c clock-out` if it left one open), `c check`, `c todo`
   for finished tasks the worker did not mark, `c set <ID> done --note
   <commits>` at a verified gate, commit the card and lane files, append the
   `progress.log` line (format in `CLAUDE.md`) in the same commit.
4. Release the worktree: `git -C WT switch --detach main`,
   `git branch -f <branch> main` (so the branch holds the committed DONE
   card), `c worktree complete <ID> --commit <landed sha>`,
   `c worktree integrate <ID> --commit <main sha holding the DONE card>`,
   and only then delete the branch. A sub-agent's `claude-C<ID>` worktree is
   then removed with `git worktree remove`; Codex worktrees stay for the
   next card.
5. File every follow-up the worker or reviewer found as a card with
   `c new`, with its Context and Scope and gate filled before committing.

## Cleanup

At card close: review the worker's `Cache artifacts` list in `scratch.org`,
make sure its temporary directories are gone, and remove `scratch.org` if it
holds nothing a later reader needs. Remove a Codex worker's worktree only
when the worker is retired.

## Decisions from Tavis

Carried over from peregrine (Tavis's decisions there, applied here until he
says otherwise):

- Land reviewed work to `main` without asking; never push.
- Bring Tavis only real decisions, each with a recommendation. New
  user-visible behaviour and changes to the template language or the import
  trust model go to Tavis.
- `c list` on main must reflect the work in progress: start each card on
  main and assign its worktree before the worker begins.
- Regressions must fail on main before a fix lands: every bug-fix assignment
  says "reproduce, record the failing regression, then fix", and the
  reviewer reverts the production files to confirm.
- Root cause over per-case patches: when a review finds the same class of
  defect a second time, redesign so the class cannot recur, rather than
  covering the new case.
- No code duplication: every assignment carries the duplication rule; the
  reviewer checks duplication first, copied test setup included.
- Reasoning effort: never xhigh. Medium for implementation and most reviews;
  high only for extra-tricky work.
- Codex models (as configured for peregrine on 2026-11-15): a bare
  `codex --yolo` is Terra at medium; coding workers run
  `codex --yolo -m gpt-6.1-terra -c model_reasoning_effort=high`; the review
  worker and design cards run `codex --yolo -m gpt-6.1-sol`; trivial cards
  can run Luna (`-m gpt-6-luna`). When Codex's weekly limit shows 0%, it runs
  on paid credits: ask Tavis before spending them.
- Claude sub-agents replace Codex when Tavis says so: coding and reviews
  both run as sub-agents (Sonnet where it fits, Opus for design or refactor
  cards), at most five at once.
- Fresh sessions between cards: restart a worker's Codex session before
  assigning its next card; restart the review worker when its context passes
  about 80 percent, between reviews.
- Plan reviews: the supervisor approves plans for small, well-specified cards
  itself; refactor and design cards get a review-worker plan review before
  code.
- Attribution in cards: correct "Tavis approved" written for a supervisor
  decision on sight; every decision message says "supervisor's call"
  explicitly.
- Session hours: when Tavis names a stop time, stop assigning 15 minutes
  before, have every worker commit WIP and clock out, commit card notes, then
  write the handoff.

Mechanics learned in peregrine:

- Codex can block on an in-pane multiple-choice question that never reaches
  the mailbox; when a worker is IDLE without a report, capture its pane.
- A sub-agent notification marked "finished" while its text says it is
  waiting means it has no live background job and will not wake: check its
  processes and send it on with SendMessage. Before closing a session,
  check each started card's branch and notes and resume a quiet sub.
- Exit 143 from a worker's build is its own shell tool timeout killing a
  command that waited on the build lock; tell it to run long jobs detached
  and poll the log.
- Orphaned clocks: when a Codex session was restarted with a clock open,
  close it as that session: read its `Session-ID` from the card's clock-in
  entry and run `C_HARNESS=codex C_SESSION_ID=<id> c clock-out <ID> --note
  "Orphaned clock of a restarted Codex session; closed by the supervisor"`.
- Reviewers sometimes clock in despite `REVIEW.md`: before a fast-forward,
  save main's card diff, check out the card, merge, and reapply the diff with
  `git apply --3way`.
- `c new` leaves a placeholder in the task body and `c set done` refuses
  until it is replaced, so fill the task body when filing. `c set done` and
  `c set cancelled` append the archive-log line themselves.
- Stub cards left uncommitted by an ended session are filled with a pointer
  to the real card, cancelled with `c set`, and committed by the supervisor.

iidy-hs decisions:

- Memory (Tavis, 2026-11-16): be careful with RAM. All builds go through
  `scripts/guarded-build` (one at a time, refuses below 6 GiB available);
  Nix builds use `--max-jobs 1 --cores 4`; GHC at most `-j4`.
- Approval enforcement (Tavis, 2026-11-16, C16): starts with a review of the
  TypeScript version (`~/src/iidy-js`) and a discussion with Tavis before
  any code. The remote-template redesign (C15) likewise starts with an
  options write-up for Tavis.
- Claude sub-agents for the 2026-11-16 batch (Tavis): Opus and Sonnet
  sub-agents work the cards, no Codex panes; brief template in
  `scripts/supervisor/CARD-BRIEF.md`.
