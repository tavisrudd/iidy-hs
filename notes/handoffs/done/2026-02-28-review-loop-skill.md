# Review Loop Skill -- Claude Skill Implementation

**Date**: 2026-02-28
**Session**: `8f647906-271e-4a66-8a76-b8142dfa8367`
**References**: This session's review workflow (reviews 1, 1b, 1c), existing `/t-review` skill

## Context

During today's session we ran an iterative code review loop:
1. First review (Opus) found ~30 issues, graded the code
2. Fixes applied across multiple commits
3. Second independent review (Opus, no access to first review) found new issues + confirmed fixes
4. Fixes applied, grade assessment (82/100)
5. Missing tests added based on review gaps
6. Third pass would re-grade

This pattern is valuable and should be a reusable Claude skill: `/t-review-loop`.

## Skill Design

### Name: `t-review-loop`
### Arguments: `<scope-glob> [--rounds N] [--target-grade N]`
### Context: `fork` (sub-agent, preserves main context)

### Behavior

1. **Round 1 — Initial Review**: Launch an Opus sub-agent to review the
   files matching the scope glob. It writes findings to
   `notes/YYYY-MM-DD-review-{N}-{slug}.md` with issues, grades (out of 100),
   and test coverage gaps. The review agent must NOT read prior review files.

2. **Fix Round**: The main agent (or user) fixes the issues found.
   This is NOT automated — the skill returns control after each review
   so fixes can be applied.

3. **Round 2..N — Re-review**: Launch a NEW Opus sub-agent (no prior
   review context) to re-review the same scope. It reads the CURRENT
   code (post-fixes), writes a new review file with a fresh grade.
   It DOES read the prior review files to assess which issues were fixed
   and which remain, and whether new issues were introduced.

4. **Ratchet**: The grade must not decrease between rounds. If it does,
   the skill flags it. The loop continues until either:
   - The target grade is reached (default: 90)
   - The configured number of rounds is exhausted (default: 3)
   - The user stops it

### Review File Format

```markdown
# Code Review {N}{letter}: {Scope Description}

**Date**: YYYY-MM-DD
**Round**: {N} of {max_rounds}
**Scope**: {file list}
**Prior reviews**: {list of prior review files, or "none (initial)"}

## Grade: {XX}/100

## Summary
[1-2 paragraph overview]

## Issues Found
### {ID}: {Title} ({Severity}: Critical/Major/Minor)
**File**: path:line
**What**: description
**Fix**: suggested fix

## Issues Fixed Since Last Review
[Only in rounds 2+. Table of prior issues and their status.]

## Test Coverage Assessment
[Gaps identified]

## Positive Observations
[Things done well]

## Grade Justification
[Breakdown of point deductions]
```

### Skill File Location

`~/.claude/skills/t-review-loop/SKILL.md`

## Codebase Reference

| What                        | Where                                        |
|-----------------------------|----------------------------------------------|
| Existing review skill       | `~/.claude/skills/t-review/SKILL.md`         |
| Example review output       | `notes/2026-02-28-review-1b-yaml-resolver-errors.md` |
| Example grade output        | `notes/2026-02-28-review-1c-yaml-resolver-errors.md` |
| Skills directory            | `~/.claude/skills/`                          |

## Delegation Strategy

| Step              | Delegate? | Agent  | Why                                          |
|-------------------|-----------|--------|----------------------------------------------|
| Write SKILL.md    | No        | Main   | Skill design is architectural / Opus-level   |

## Workflow Instructions

1. Read this file
2. Read the example review files listed above for format reference
3. Write `~/.claude/skills/t-review-loop/SKILL.md`
4. Test by dry-reading the skill to confirm it's coherent

## Progress

- [ ] Write the skill file
- [ ] Verify it's syntactically correct YAML frontmatter + markdown

## Handoff Notes

(none yet)
