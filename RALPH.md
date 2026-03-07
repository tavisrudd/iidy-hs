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
- WORKPLAN.md phase index is current (status, links)
- Current phase doc checkboxes reflect actual state
- Session handoff doc created in notes/handoffs/ with: what done, deviations, next steps
- progress.log has entries for all completed chunks
- MEMORY.md reflects any new learnings or status changes
- All doc updates committed alongside code
- No orphaned TODOs — anything deferred is tracked in a phase doc

## Session Size & Delegation
- Keep sessions SHORT. Each session = 1-2 good green commits, then exit.
- If a subphase is too large for 1-2 commits, split it across sessions.
- Exit cleanly so the ralph loop continues with fresh context.
- Don't try to do everything in one session. Small, focused, done.
- Use sub-agents (Task tool) for research, exploration, and parallel work to keep main context clean.
- Delegate to Sonnet sub-agents for straightforward implementation
  after Opus designs the interface. Review their work.
- Use Explore agents for codebase searches rather than flooding main context with grep results.
