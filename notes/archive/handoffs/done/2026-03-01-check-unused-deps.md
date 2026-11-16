# Add make check-unused-deps Target for CI -- Tooling

**Status**: DONE
**Date**: 2026-03-01
**References**: `Makefile`, `.github/workflows/ci.yml`, `iidy-hs.cabal`

## Context

No mechanism exists to detect unused dependencies in the cabal file. Over time,
dependencies can accumulate that are no longer used (e.g., after refactoring).
Add a `make check-unused-deps` target that runs from CI.

## Tool Options

### Option A: packunused (recommended)

`packunused` analyzes `.hi` files after a build to detect unused package
dependencies. It's the standard Haskell tool for this.

```bash
# Install: cabal install packunused (or via nix)
# Run after build:
cabal build
packunused
```

Output lists unused deps. Exit code 1 if any found.

### Option B: cabal-plan-bounds / manual script

Parse the `.cabal` file and cross-reference with actual imports. More complex,
less standard.

### Option C: weeder

`weeder` finds dead code (not just unused deps). More comprehensive but heavier.
Overkill for just dependency checking.

**Recommendation**: Option A (`packunused`) if available in nixpkgs. If not,
a simple script using `ghc-pkg` + module import analysis.

## Implementation

### 1. Add packunused to flake.nix dev dependencies

Check if `packunused` is in nixpkgs. If not, use `cabal-install` to install it
or write a simple shell script alternative.

**Simple script alternative** (no extra dep needed):

```bash
#!/usr/bin/env bash
# scripts/check-unused-deps.sh
# Checks for unused dependencies by analyzing .hi interface files
set -euo pipefail

echo "Building to generate .hi files..."
cabal build -v0

echo "Checking for unused package dependencies..."
# Use GHC's -ddump-minimal-imports or packunused if available
if command -v packunused &>/dev/null; then
  packunused
else
  echo "packunused not found, skipping unused dep check"
  exit 0
fi
```

### 2. Add Makefile target

```makefile
check-unused-deps:
	scripts/check-unused-deps.sh
```

### 3. Add to CI pipeline

In `.github/workflows/ci.yml`, add to the `ci` make target or as a separate step:

```makefile
ci:
	$(MAKE) build-strict
	$(MAKE) test
	$(MAKE) check-unused-deps
	cabal run iidy-hs -- --help
	cabal run iidy-hs -- --version
```

### 4. Verify no false positives

Run the check locally first. Some deps may appear unused but are needed at
runtime (e.g., `amazonka-*` plugins loaded dynamically). If so, add an
allowlist to the script.

## Alternative: cabal-extras approach

If `packunused` is problematic, a simpler approach:

```bash
#!/usr/bin/env bash
# Extract deps from cabal file, grep for their use in source
set -euo pipefail
cabal_file="iidy-hs.cabal"
# Extract build-depends package names
deps=$(sed -n '/build-depends/,/^[^ ]/p' "$cabal_file" | grep -oP '[\w-]+(?=\s)' | sort -u)
for dep in $deps; do
  # Check if any module from the package is imported
  if ! grep -rq "import.*${dep//-/.}" src/ app/; then
    echo "Possibly unused: $dep"
  fi
done
```

This is approximate but catches obvious unused deps without extra tooling.

## Codebase Reference

| What                 | Where                           |
|----------------------|---------------------------------|
| Makefile             | `Makefile`                      |
| CI workflow          | `.github/workflows/ci.yml`      |
| Cabal file           | `iidy-hs.cabal`                 |
| Nix flake            | `flake.nix`                     |

## Build/Test Commands

Per CLAUDE.md.

## Delegation Strategy

- **Can delegate?** Yes
- **Sub-agent type**: Sonnet
- **Why**: Tooling/scripting task. Check if packunused is in nixpkgs first.
  If not, implement the simple script alternative. Wire into Makefile and CI.

## Progress

- [ ] Determine if packunused is available in nixpkgs
- [ ] Implement check script (packunused or alternative)
- [ ] Add `check-unused-deps` Makefile target
- [ ] Add to CI pipeline (Makefile `ci` target)
- [ ] Run locally to verify no false positives
- [ ] Build clean + all tests pass
