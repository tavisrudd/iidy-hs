# Supervisor handoff (iidy-hs) — written 2026-11-16 by the setup session

## Mode for this batch

Tavis, 2026-11-16: work today's batch with Claude sub-agents, Opus and
Sonnet, no Codex panes. No mailbox and no tmux; sub-agents report in their
final reply, and you steer them with SendMessage. Launch each with
`scripts/supervisor/CARD-BRIEF.md` filled in.

- Opus: security cards, design and concurrency work, and reviews of those.
- Sonnet: bounded fixes, test additions, docs, card refinement, and reviews
  of Sonnet work.
- Never `isolation: worktree` on the Agent tool (CLAUDE.md). Worktrees are
  made by you under `~/src/iidy-hs/.supervisor/worktrees/claude-C<ID>`.

## Limits that bite

- RAM (Tavis): every build through `scripts/guarded-build` (one at a time,
  refuses below 6 GiB). At most two coding subs building at once, plus up to
  two notes-only research subs (no builds) and one reviewer. Check
  `scripts/supervisor/status.sh` before launching a wave.
- Toolchain: GHC 9.12.3 since C3. A shell started before C3 still finds
  9.10.3 (this setup session's hook runs did); start fresh or
  `direnv reload` in `~/src/iidy-hs` before your own builds and landings.
  Each worktree needs `direnv allow` at creation.
- Flaky hang (C6): tests can hang and ignore SIGTERM; the pre-commit hook
  now has a 60 s per-test timeout. `kill -9` a stuck `iidy-hs-test`.
- Cards filed before C23 lack the worker format (`Allowed paths:`,
  `Out of scope:`, `Done when:` checklist, `Stop and record if:`). Refine
  each before assigning; a Sonnet sub can draft a batch on main (notes
  only, named cards only, no `c set`), and you vet, `c stamp`, `c check`
  and commit.

## State at handoff

- Nothing started; no worktrees; `c next` lists 17 TODO cards. Main is
  clean at the C23 closeout.
- C15 and C16 begin with work for Tavis: C15 an options write-up for the
  remote-template trust model, C16 a review of the TypeScript approval flow
  (`~/src/iidy-js`, `src/cfn/approval/index.ts`,
  `src/cfn/AbstractCloudFormationStackCommand.ts`,
  `src/cfn/loadStackArgs.ts`) and a discussion with Tavis. Assign only
  their first task; no code until he decides. C22 waits on C15.
- C11 adds tests for get-import, which C13 also changes: run C13 first.
- Open question for Tavis from C7: should `render` also get an AWS
  environment (Rust's does not)? Not filed as a card yet.
- Held-back libraries from C3 (microlens, http-client-tls, crypton,
  optparse-applicative): recommendation was to leave them; Tavis has not
  answered.

## Proposed batch (supervisor's call; adjust to `c next` and file overlap)

Wave 1
- C14 trust check fails open (A, security): Opus coder, Opus reviewer.
- C13 get-import --query, newline, JSON layout: Sonnet coder, Sonnet
  reviewer.
- C15 task 1, options write-up: Opus, notes only.
- C16 task 1, TypeScript approval review: Opus, notes only.
- First, a Sonnet refinement sub for C14, C13, C6, C9, C8, C10.

Wave 2
- C6 test-suite hang: Opus (concurrency). Reproduce in about 30 full runs;
  if not reproduced on GHC 9.12.3, park it with what to record next time.
- C9 terminal width: Sonnet.

Wave 3 (refine first)
- C8 parseYaml key order (Sonnet), C10 dummy StackArgs (Sonnet), C11 tests
  after C13 (Sonnet), C19 token redaction (Sonnet coder, Opus reviewer),
  C18 control characters after C9 (Sonnet coder, Opus reviewer), C20
  resource limits (Opus), C17 stack-args credentials (Opus), C5 docs to Org
  (Sonnet; touches docs only).
- Later: C12, C21 (priority C), C22 after C15.

File overlap to avoid running together: C14/C20/C19 (all under
`src/Iidy/Yaml/Imports/`), C9/C18 (`src/Iidy/Output/`), C13/C11
(get-import tests), C17/C12 (`StackArgsLoader.hs`), C10/C17
(`app/Main.hs` possibly).

## Next steps

1. Start the session with `/supervise`; read RUNBOOK, PROTOCOL, REVIEW.
2. Launch the refinement sub for wave 1 and 2 cards; vet and commit.
3. Start wave 1 per the runbook's Assigning section.
4. Tell Tavis the plan in a few sentences and the two open questions above.
