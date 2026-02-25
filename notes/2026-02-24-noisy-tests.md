# Noisy test cases (captured February 24, 2026)

> **Note:** This file was written by Codex.

Command used:

```
cabal test iidy-hs-test | tee test-output.log
```

The following test cases produced large amounts of stdout/stderr (AWS stack metadata, events, etc.) during the run:

- `Fixtures.yaml-iidy-syntax/frompairs`
- `Fixtures.yaml-iidy-syntax/groupby`
- `Fixtures.yaml-iidy-syntax/if-conditional`
- `Fixtures.yaml-iidy-syntax/include-equivalence`
- `Fixtures.yaml-iidy-syntax/map`
- `Fixtures.yaml-iidy-syntax/maplisttohash`
- `Fixtures.yaml-iidy-syntax/mapvalues`
- `Fixtures.yaml-iidy-syntax/merge`
- `Fixtures.yaml-iidy-syntax/mergemap`
- `Fixtures.yaml-iidy-syntax/split`
- `Fixtures.yaml-iidy-syntax/let`
- `Fixtures.yaml-iidy-syntax/join`
- `Fixtures.yaml-iidy-syntax/jmespath-query`
- `Fixtures.yaml-iidy-syntax/include-handlebars-equivalence`

Each of these emitted repeated “Command Metadata”, stack descriptions, and event logs even when the test passed. See `test-output.log` for the captured raw output from this run.

Next step: introduce a reusable `runSilent` helper for tests and start applying it to these noisy cases so output only appears when a test fails.
