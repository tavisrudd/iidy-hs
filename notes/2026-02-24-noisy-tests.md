# Noisy test cases (corrected February 25, 2026)

> **Note:** Original file written by Codex (Feb 24). Corrected after analysis
> showed Codex misidentified the noisy tests due to parallel interleaving.

## Original (incorrect) claim

Codex listed 14 `Fixtures.yaml-iidy-syntax/*` tests as noisy. This was wrong.
Those tests produce zero noise — the apparent noise was stdout from Integration
tests interleaving with Fixture test names during parallel execution.

## Actually noisy tests

All noise (~528 lines per run) comes from **12 tests in `Test.IntegrationTest`**
that call `renderOutputData` / `renderOutputDataJson`, which write directly to
stdout/stderr.

### Integration > InteractiveRenderer (10 noisy)

| Test                                             | ~Lines | Content                                       |
|--------------------------------------------------|--------|-----------------------------------------------|
| handles all OutputData variants without crashing  |    131 | All 26 OutputData types rendered               |
| colored handles all OutputData variants           |    131 | Same + ANSI escape codes                       |
| processes create-stack sequence in order          |     40 | Metadata + definition + events + summary       |
| processes describe-stack sequence in order        |     41 | Metadata + definition + events + contents      |
| processes delete-stack sequence in order          |     42 | Metadata + definition + confirmation + polling |
| processes changeset sequence in order             |     36 | Metadata + definition + changeset result       |
| processes drift sequence in order                 |     36 | Metadata + definition + drift resources        |
| processes stack-absent error                      |     15 | Metadata + absent info                         |
| processes lint+approval sequence                  |     28 | Validation + approval + diff                   |
| handles stack list                                |      2 | Header + one row                               |

### Integration > JsonRenderer (2 noisy)

| Test                                             | ~Lines | Content                |
|--------------------------------------------------|--------|------------------------|
| handles all OutputData variants without crashing  |     32 | One JSON blob per variant |
| handles create-stack sequence                     |      8 | JSON blobs per step      |

### Integration > OutputSequences (0 noisy)

These 4 tests only check data structures, never call renderers.

## Root cause

Both `InteractiveRenderer` and `JsonRenderer` write to hardcoded `stdout`/`stderr`
(`TIO.putStrLn`, `TIO.putStr`, `hFlush stdout`). The integration tests call
these renderers to verify they don't crash, producing ~528 lines of side-effect
output per run.

## Fix approach

See `notes/handoffs/2026-02-25-fix-noisy-tests.md`.
