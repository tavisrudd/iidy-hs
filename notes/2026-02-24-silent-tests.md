# Experiment: silencing noisy tests

- **Date:** February 24, 2026
- **Context:** Wanted to keep `cabal test` output quiet by wrapping noisy tests with `System.IO.Silently.capture`.

## Approach
1. Added a `runSilent` helper in `test/Test/Util.hs` using `hCapture [stdout, stderr]` to buffer logs.
2. Wired `silentTestCase` into a couple of fixture/integration tests as a proof of concept.

## Findings
- Tasty's own progress/output is printed via the same stdout handle. Redirecting stdout/stderr globally (even briefly) captures not only the test's output but also Tasty's runner output that is interleaved from other threads.
- As soon as `runSilent` ran, the suite appeared to "exit early" because subsequent Tasty messages (including remaining test names and the summary) were captured and never flushed unless the wrapped assertion failed.
- This made the entire test run look truncated despite all tests actually running to completion in the background.

## Conclusion / Next steps
- Global handle capture is too invasive for this suite because it interferes with Tasty's reporting.
- Future work should silence tests by injecting quiet sinks directly into the output-producing code paths (e.g., letting renderers write to an arbitrary `Handle`/callback) rather than redirecting `stdout`.
- Leave the suite noisy for now, relying on `notes/noisy-tests.md` as the current inventory of offenders.
