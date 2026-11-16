# Staircase Nesting Review

**Date**: 2026-03-02
**Context**: paramGetHistory had 7-level deep case nesting before being flattened. Find and fix other instances of the same pattern across the codebase.

---

## What to look for

Deep case-of nesting (3+ levels) where each level handles `Either`/`Maybe` results:
```haskell
case foo of
  Left err -> handleErr
  Right x -> do
    case bar x of
      Left err -> handleErr
      Right y -> do
        case baz y of
          ...
```

## Fix patterns

1. **Extract helper functions**: Move the inner logic to a named `where` clause
2. **Early returns**: Use guards with `| null xs -> pure $ Left ...`
3. **ExceptT** (if appropriate): For IO chains with many `Either` results

## Example: paramGetHistory (before/after)

**Before** (7 levels):
```haskell
case result of
  Left ex -> ...
  Right entries
    | null entries -> ...
    | otherwise -> do
        case reverse sorted of
          [] -> ...
          (current : rest) -> do
            case tagsResult of
              Left err -> ...
              Right tags -> case args.pgaFormat of
                ParamFormatRaw -> ...
                fmt -> ...
```

**After** (3 levels):
```haskell
case result of
  Left ex -> ...
  Right entries | null entries -> ...
  Right entries -> do
    ...
    case tags of
      Left err -> pure (Left err)
      Right tagMap -> pure $ Right $ formatHistory ...
```

## Files to audit

These files are known to have deep `case` nesting or `try @SomeException` staircase patterns:

| File                                           | Reason                                          |
|------------------------------------------------|-------------------------------------------------|
| `src/Iidy/Cfn/Operations/TemplateApproval.hs`  | 6+ levels in templateApprovalReview             |
| `src/Iidy/Cfn/Operations/Changeset.hs`         | Multiple AWS calls with Either chaining         |
| `src/Iidy/Cfn/Operations/CreateOrUpdate.hs`    | Complex branching on stack state                |
| `src/Iidy/Cfn/StackArgsLoader.hs`              | loadStackArgs has 4-level nesting               |
| `src/Iidy/Cfn/Operations/DeleteStack.hs`       | Confirmation + AWS call chain                   |
| `src/Iidy/Params/Client.hs`                    | paramGet, paramGetByPath still have some nesting |
| `app/Main.hs`                                  | Command dispatch with nested case matches       |

## Strategy

- Use a grep/explore agent to find all instances of 4+ level case nesting
- For each, determine the best flattening approach (helper extraction, early return, or ExceptT)
- Fix one file at a time, test after each
- Don't change behavior — only refactor structure

## Constraints

- Zero test failures after each change
- `-Wall -Wcompat` clean
- Keep session short: 2-3 commits max
