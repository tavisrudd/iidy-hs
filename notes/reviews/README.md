# Reviews

Code review documents produced by the `/t-review` and `/t-review-loop` skills.

## Naming Convention

```
YYYY-MM-DD-review--<slug>.md                    single-round review
YYYY-MM-DD-review--<slug>--round-<N>.md         multi-round review
```

Double-dash `--` separates the `review` prefix from the slug and the
round suffix. Date is the review creation date.

### Persona-based reviews

For reviews adopting a specific expert persona, the slug follows the
pattern `<area>-persona:<name>`:

```
2026-03-02-review--architecture-persona:hickey.md
2026-03-02-review--api-design-persona:russell.md
```

### Multi-round review loops

We often run iterative review-fix-review-fix sessions on a subsystem.
Each round produces a new review file with an incrementing `--round-N`
suffix. Fixes happen between rounds, so the sequence tells the full
story of how a subsystem improved:

```
2026-02-28-review--yaml-resolver-errors--round-1.md
2026-02-28-review--yaml-resolver-errors--round-2.md
2026-02-28-review--yaml-resolver-errors--round-3.md
```

## Related Handoff Documents

Review findings are tracked and fixed via handoff documents in
`notes/handoffs/`. The naming pattern is `post-review--<area>-fixes`:

| Review Area              | Fix-Tracking Handoff                                                          |
|--------------------------|-------------------------------------------------------------------------------|
| General (all open)       | `notes/handoffs/2026-03-02-post-review-fixes.md`                             |
| Interactive renderer     | `notes/handoffs/done/2026-02-28-post-review--interactive-renderer-fixes.md`   |
| YAML resolver errors     | `notes/handoffs/done/2026-02-28-post-review--yaml-resolver-errors-fixes.md`   |
| YAML resolver (leftover) | `notes/handoffs/done/2026-02-28-post-review--yaml-resolver-errors-remaining-fixes.md` |
| CFN operations polling   | `notes/handoffs/done/2026-03-01-post-review-loop--cfn-operations-polling.md`  |
| Interactive renderer (2) | `notes/handoffs/done/2026-03-01-post-review-loop--interactive-renderer.md`    |
| Spec-critical            | `notes/handoffs/done/2026-03-03-post-review--spec-critical-fixes.md`          |
