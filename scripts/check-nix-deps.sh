#!/usr/bin/env bash
# Check that all cabal build-depends have corresponding entries in flake.nix.
# Packages bundled with GHC (base, array, etc.) are excluded.
set -euo pipefail

CABAL_FILE="iidy-hs.cabal"
FLAKE_FILE="flake.nix"

# Packages that ship with GHC and don't need flake entries
GHC_BUNDLED="base array async unix"

# Extract package names from cabal build-depends (all stanzas)
cabal_deps=$(
  grep -E '^\s*,' "$CABAL_FILE" \
    | sed 's/,//; s/>=.*//; s/>.*//; s/<.*//; s/==.*//; s/\^.*//; s/ *$//' \
    | tr -d ' ' \
    | grep -v '^$' \
    | sort -u
)

# Extract package names from flake.nix haskellDeps
flake_deps=$(
  grep -oP 'hpkgs\.\K[a-zA-Z0-9_-]+' "$FLAKE_FILE" \
    | sort -u
)

missing=""
for dep in $cabal_deps; do
  # Skip GHC-bundled packages
  skip=false
  for bundled in $GHC_BUNDLED; do
    if [ "$dep" = "$bundled" ]; then
      skip=true
      break
    fi
  done
  $skip && continue

  # Skip self-reference
  [ "$dep" = "iidy-hs" ] && continue

  # Check if in flake
  if ! echo "$flake_deps" | grep -qx "$dep"; then
    missing="$missing $dep"
  fi
done

if [ -n "$missing" ]; then
  echo "ERROR: cabal deps missing from flake.nix haskellDeps:$missing"
  echo "Add them to the haskellDeps list in flake.nix"
  exit 1
fi
