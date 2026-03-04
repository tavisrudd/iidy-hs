# ReaderT / RIO Pattern Investigation — COMPLETED

**Date**: 2026-03-03 (created), 2026-03-04 (resolved)
**Status**: COMPLETED — ReaderT rejected, simpler approach chosen
**Successor**: `2026-03-04-widen-cfncontext.md`

---

## Outcome

A full ReaderT prototype was implemented, tested (1246 tests pass), and
evaluated. The approach added net +290 lines, introduced `liftIO` noise
everywhere, and didn't justify the monad transformer overhead given only
2 levels of threading depth.

The patch is preserved at:
`notes/patches/0001-Introduce-ReaderT-based-CfnM-monad-for-CFN-operation.patch`

The recommended alternative — widening `CfnContext` with the 3 missing
fields and optionally bundling `StackArgs + Maybe FilePath` into a
`StackInput` record — achieves the same signature reduction (6 params → 2)
with zero machinery. See successor doc for full design.
