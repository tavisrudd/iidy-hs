# Memory & Context Audit

**Date**: 2026-03-02
**Purpose**: Comprehensive audit of all memory files, session context, handoff docs, and project notes. Ensure everything is accurate, non-redundant, and properly located.

---

## Context

Over 48 sessions the project has accumulated:
- Memory files in `~/.claude/projects/-home-tavis-src-iidy-hs/memory/`
- Handoff docs in `notes/handoffs/` (4 active, 18 in `done/`)
- Project notes in `notes/` (research docs, phase docs, reviews)
- `CLAUDE.md` (operational rules), `WORKPLAN.md` (phase tracking), `DIVERGENCES.md`
- `progress.log` (session-by-session append log)

Session 48 did a partial cleanup (trimmed MEMORY.md from 78→14 lines, moved sub-agent git rules to CLAUDE.md, deleted stale `error-display-gap.md`). A more thorough pass is needed.

## Principles

From user (Session 48):
- **Memory files should be sparse** — status pointers and gotchas only
- **Operational rules go in CLAUDE.md**, not memory
- **If unsure where something belongs, ask the user**

## Audit Scope

### 1. Memory files
- `~/.claude/projects/-home-tavis-src-iidy-hs/memory/MEMORY.md`
- Check for any other files that may have been recreated in that directory
- Verify all entries are accurate against actual codebase state
- Remove anything that duplicates CLAUDE.md

### 2. CLAUDE.md
- Check for stale instructions (e.g., phase-era rules that no longer apply)
- Check for contradictions between sections
- Verify the end-of-session gate still makes sense (we're past the phase system)
- "Research Before Implementation" — still relevant or phase-era artifact?
- "Progress Logging" — format references "Chunk X.Y" which is phase-era

### 3. Handoff docs (notes/handoffs/)
- Which active handoffs are still relevant?
- Should any be moved to `done/`?
- Is the post-review-fixes handoff progress table accurate?

### 4. Project notes (notes/)
- What's in `notes/` at the top level? Still relevant?
- `notes/phases/` — archive or still needed?
- Review files (`notes/2026-03-02-*-review.md`) — are these reference material or action items?

### 5. progress.log
- Is it current?
- Does it have entries for all completed work?

### 6. WORKPLAN.md
- Is the phase index accurate?
- Does it still serve a purpose post-completion?

## Deliverables

1. List of changes made (files modified/deleted, content moved)
2. Updated MEMORY.md if needed
3. Updated CLAUDE.md if stale instructions found
4. Handoffs moved to `done/` if completed
5. Summary of what was found and fixed

## Delegation

- **Can delegate?** Yes — this is research + cleanup, no architectural decisions
- **Sub-agent type**: Opus (needs judgment about what's stale vs useful)
- Main agent should review proposed CLAUDE.md changes before committing
