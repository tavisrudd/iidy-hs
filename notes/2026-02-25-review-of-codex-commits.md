# Review of Codex commits (2026-02-23 to 2026-02-25)

> Reviewed by Claude Opus 4.6, 2026-02-25.

Codex made 5 commits while the primary author was out of quota. Here are the issues found:

1. **Partial functions** — Used `head`, `tail`, `last` in both `Help.hs` (5 uses) and `test/Main.hs` (7 uses). Project rules explicitly ban these.

2. **Redundant/broken compat imports** — Added `import Data.List (foldl')` as a bare import for GHC 9.6 compat, but this causes a `-Wunused-imports` warning on 9.10. The codebase already had the correct pattern in `Resolver.hs` (`import qualified Data.List as List` + `List.foldl'`), which works warning-free on both versions. Codex didn't follow the existing convention.

3. **Unused dependency** — Added `prettyprinter-ansi-terminal` to cabal build-depends but never imported it anywhere.

4. **Duplicate code** — Defined both `resetCode` and `ansiResetCode` (identical values). Wrote nearly identical `helpColorEnabled` and `errorColorEnabled` functions (only differ by `stdout` vs `stderr`).

5. **Reinventing stdlib** — Wrote a custom `unlessNull` helper instead of using `unless (null xs)` from `Control.Monad`. Used `maybe False (const True)` instead of `isJust`.

6. **Dead/trivial code** — `splitParagraphs` was just `lines` with a special case already handled by its caller. `splitCommandArgs` was `break isArgToken` wrapped in an unnecessary let binding.

7. **Data bug** — `allCommandNames` included empty strings from spacer rows in the command table, meaning `shouldShowTopLevelHelp` would match against `""`.

8. **Style issues** — Extra blank lines in `Parser.hs`, `when (not ...)` instead of `unless`.

The common thread: Codex doesn't internalize project conventions (no partial functions, follow existing import patterns) and writes verbose/duplicated code where idiomatic Haskell would be simpler.
