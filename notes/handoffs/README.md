# Handoffs

Work-batch tracking documents. Originally named for cross-session handoffs,
but also used to scope and record work done within a single session —
a session may create and complete many handoffs via sub-agents.

## Directory Layout

```
notes/handoffs/
  README.md          ← this file
  <date>-<slug>.md   ← active handoffs (in progress or pending)
  done/              ← completed handoffs (moved here when all items are done)
```

## Naming Convention

```
YYYY-MM-DD-<kebab-case-slug>.md
```

Date is the creation date. Slug is a short descriptive topic (e.g.,
`fix-performance`, `cli-output-phases-13.1-13.3`, `post-review-fixes`).

## Document Types

### Session Handoff (`/t-handoff`)

For work that spans multiple sessions. Contains session context, progress
tracking, and notes for the next agent.

```markdown
# Title — Plan Type

**Date**: YYYY-MM-DD
**Session**: N (`$CLAUDE_SESSION_ID`)
**References**: links to prior art, source material

## Context
## Key Architecture Decisions  (if non-trivial)
## Chunks / Issues to Fix      (adapt to work type)
## Codebase Reference           (paths that took effort to find)
## Delegation Strategy           (which chunks can go to sub-agents)
## Progress                      (checkboxes)
## Handoff Notes                 (per-chunk session logs)
```

### Future Task (`/t-later`)

Self-contained task spec for a fresh agent with zero prior context.
Not a session handoff — no "where I left off," just "what needs doing."

```markdown
# Task Title

**Date**: YYYY-MM-DD
**Created by**: $CLAUDE_SESSION_NUM (`$CLAUDE_SESSION_ID`)
**Purpose**: one-line summary

## Context
## Scope
## Work Items
## Codebase Reference
## Principles / Constraints
## Delegation
```

## Required Headers

Every handoff file must have at minimum:

| Header       | Value                                                  |
|--------------|--------------------------------------------------------|
| `**Date**`   | `YYYY-MM-DD`                                          |
| `**Status**` | `DONE` (in `done/`), or a short description if active |

## Lifecycle

1. **Create** — `/t-handoff <slug>` or `/t-later <slug>` puts the file
   in `notes/handoffs/`.
2. **Update** — each session marks progress, adds handoff notes.
3. **Complete** — when all items are done, move to `notes/handoffs/done/`
   and set `**Status**: DONE`. The `/t-done` skill handles this.
4. **Archive** — `done/` files are kept indefinitely for reference.
   Bulk research artifacts go to `notes/archive/` instead.
