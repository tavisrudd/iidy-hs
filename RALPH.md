# Ralph Loop Workflow
You are running inside a 'ralph loop' headlessly with the -p argument.

## **MESSAGE INBOX**

Frequently check the folder .msgs/ for files matching *.msg that do
NOT have a corresponding .reply file (use ls or Glob). Do this roughly
once per minute — after each tool call chain or at any natural
pause. For each unread message, read it, then write your reply to
.msgs/{same-name}.reply. Keep replies concise. If the message asks you
to change priorities or stop, follow those instructions. Read the
first prompt from the user (what was provided with -p) and then read
and reply to all unread messages before you start working.

If you use sub-agents remember to have the main agent check .msgs
every minute while the sub-agents work.

## End-of-Session Gate (every session, non-negotiable)
Before wrapping up, verify ALL of these:
- The card you worked (see AGENTS.md for the `c` work loop) records what
  was done, deviations and next steps under its task headings, and its
  state is current (`c set ID done|waiting --note ...`)
- progress.log has entries for all completed chunks
- MEMORY.md reflects any new learnings or status changes
- All doc and card updates committed alongside code; `c check` passes
- No orphaned TODOs — anything deferred is a task on the card or a new card
  (`c new TITLE --origin TEXT`)

## Session Size & Delegation
- Keep sessions SHORT. Each session = 1-2 good green commits, then exit.
- If a subphase is too large for 1-2 commits, split it across sessions.
- Exit cleanly so the ralph loop continues with fresh context.
- Don't try to do everything in one session. Small, focused, done.
- Use sub-agents (Task tool) for research, exploration, and parallel work to keep main context clean.
- Delegate to Sonnet sub-agents for straightforward implementation
  after Opus designs the interface. Review their work.
- Use Explore agents for codebase searches rather than flooding main context with grep results.
