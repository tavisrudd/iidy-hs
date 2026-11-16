# Session 12: Workflow Restructuring

**Date**: 2026-02-21
**Status**: DONE

## What was done
- Reviewed project brief, WORKPLAN.md, centaur workflow analysis with user
- Clarified critical rules: feature complete (no shortcuts), gate integrity, small commits, .msgs/ checking
- Fixed Risk Register: NTP is critical (not droppable), schema validation must be full (not minimal)
- Restructured WORKPLAN.md from monolithic doc to lightweight index
- Created per-phase docs: phase-7-error-display.md, phase-8-remaining-features.md, phase-9-final-verification.md
- Created notes/sessions/ for per-session handoffs
- Updated MEMORY.md with critical rules

## What's next (Session 13)

### FIRST: Audit previous phases for skipped/deferred/dropped items
Before starting Phase 7, review ALL prior session notes and the old WORKPLAN.md git history for:
- Items marked "deferred" or "later" or "skip"
- Items marked "won't implement" or "drop feature"
- Unchecked gate items from Gates 1-6
- Any TODO/STUB/undefined still in the codebase
- Features from the Rust version that were noted but never implemented

Create a `notes/phases/phase-0-audit.md` documenting everything found. Add missing items to phase-7, phase-8, or a new phase doc as appropriate. Commit the audit before starting any code work.

Key places to check:
- `git log --all --oneline` for session commit messages mentioning "defer", "skip", "stub"
- `grep -r 'undefined\|TODO\|STUB\|FIXME\|error "Not implemented"' src/`
- `progress.log` for any noted deferrals
- `notes/` research docs for features identified but never tracked
- MEMORY.md "Remaining Work" sections
- The old WORKPLAN.md (check git history) Gates 4-6 unchecked items

### THEN: Start Phase 7: Error Display System
- Begin with chunk 7.1: wire up EnhancedPreprocessingError conversion
- Read phase-7-error-display.md for detailed chunks and verification criteria
- Check .msgs/ after every tool call chain

### END-OF-SESSION GATE (every session, non-negotiable)
Before wrapping up any session, verify:
- [ ] WORKPLAN.md phase index is current (status, links)
- [ ] Current phase doc has all checkboxes updated to reflect actual state
- [ ] Session handoff doc created/updated with what was done, deviations, next steps
- [ ] progress.log has entries for all completed chunks
- [ ] MEMORY.md reflects any new learnings, decisions, or status changes
- [ ] All doc updates committed alongside code (not separate or forgotten)
- [ ] No orphaned TODOs — anything deferred is tracked in a phase doc
