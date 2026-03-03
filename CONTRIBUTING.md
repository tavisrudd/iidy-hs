# Contributing to iidy-hs

## Setup

This project uses Nix for reproducible builds. After cloning:

```
nix develop          # enter dev shell with GHC, cabal, and all deps
direnv allow         # or use direnv for automatic shell activation
```

A pre-commit hook runs `-Wall -Wcompat -Werror` builds and the full
test suite. Commits that break the build or fail tests are rejected.

## Building and testing

```
cabal build          # compile
cabal test           # run all tests
```

## Coding standards

- `-Wall -Wcompat` clean, zero warnings
- Explicit type signatures on all top-level bindings
- Prefer `Text` over `String`
- Use qualified imports for amazonka, aeson, containers
- No orphan instances
- No partial functions (`head`, `tail`, `fromJust`, etc.)
- All tests must be offline and deterministic (use mock fixtures, no AWS calls)
- Meaningful names over comments -- comment only the non-obvious

## Submitting changes

1. Fork the repo and create a branch
2. Make your changes
3. Ensure `cabal build` and `cabal test` pass with zero warnings and zero failures
4. Open a pull request with a clear description of what and why

## Reporting issues

Open an issue on GitHub with:
- What you expected to happen
- What actually happened
- The command you ran and its output
- Your OS and GHC version (`ghc --version`)
