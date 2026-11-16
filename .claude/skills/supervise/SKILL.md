---
name: supervise
description: Start or resume supervising the workers (Codex panes or Claude sub-agents) that work iidy-hs cards. Use when Tavis starts a session with "supervise" or asks to check on, steer or land worker output.
---

# Supervise the iidy-hs workers

You are the supervisor of workers working iidy-hs cards: Codex sessions in
tmux panes, or Claude sub-agents when Tavis says so. Tavis does not run them
unsupervised; you assign cards, review, land and clean up.

## Start of session

1. Read `scripts/supervisor/RUNBOOK.md` (your procedure and Tavis's
   decisions), `scripts/supervisor/PROTOCOL.md` (the contract the workers
   follow) and `scripts/supervisor/REVIEW.md` (the review worker's brief) in
   full, then `~/.cache/iidy-hs/supervisor/handoff.md` (the last session's
   in-flight picture) if it exists.
2. Follow `AGENTS.md` and `CLAUDE.md` as the main agent: read the lane
   index (`notes/main/index.org`) and `c next`.
3. Rebuild the current picture without trusting memory:
   - `c list --state started` and `c list --state waiting`;
   - `c worktree list`;
   - `scripts/supervisor/status.sh -v`;
   - `tail -20 ~/.cache/iidy-hs/supervisor/mailbox.log`;
   - for detail on one Codex worker: `tmux capture-pane -p -t PANE -S -60`.
   If `~/.cache/iidy-hs/supervisor/` is missing, the workers are not set up
   yet: follow the runbook's Setup section, asking Tavis before launching
   Codex panes and which kind of worker to use.
4. If Codex panes are running, arm the mailbox watch with the Monitor tool:
   `tail -n0 -F ~/.cache/iidy-hs/supervisor/mailbox.log 2>/dev/null | grep --line-buffered -E 'worker='`
   with the maximum timeout, and re-arm it on every expiry.
5. Handle anything unanswered: a `ready`, `question`, `blocked` or
   `budget-spent` line with no reply since it was written. If a pane has no
   Codex running, ask Tavis before relaunching it.
6. Tell Tavis in a few sentences what each worker is doing, what is waiting
   on you, and what is waiting on him.

## During the session

Follow the runbook for every event: refine a card before assigning it,
review before landing, one numbered fix round at a time, fast-forward
landing, card notes committed by you with `c check`, then the next card on a
fresh branch. Message Codex workers by writing the text to a file and
running `scripts/supervisor/send.sh PANE FILE`; message sub-agents with
SendMessage. Keep the WIP cap and the order from `c next`. Keep memory in
check: every build goes through `scripts/guarded-build`. Bring Tavis only
real decisions, each with a recommendation.

## End of session

Before the session ends, or when Tavis asks you to get ready for a fresh
session: record any new procedure or decision in `RUNBOOK.md` and commit it,
then rewrite `~/.cache/iidy-hs/supervisor/handoff.md` with each worker's
model, effort, card and state, the rules that bite on cards in flight, the
next cards per worker, and any decision waiting on Tavis.
