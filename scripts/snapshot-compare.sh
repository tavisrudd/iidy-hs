#!/usr/bin/env bash
# Compare Haskell render output against Rust snapshots
set -euo pipefail

IIDY_HS="$HOME/src/iidy-hs"
RUST_SNAPS="$HOME/src/iidy/tests/snapshots"
FIXTURES="$IIDY_HS/test-fixtures/example-templates"
PASS=0
FAIL=0
SKIP=0

compare_fixture() {
    local fixture_path="$1"
    local snap_name="$2"
    local snap_file="$RUST_SNAPS/example_templates_snapshots__auto_discovered_${snap_name}.snap"

    if [[ ! -f "$snap_file" ]]; then
        echo "SKIP: $fixture_path (no Rust snapshot)"
        ((SKIP++)) || true
        return
    fi

    # Extract snapshot content (skip header lines up to and including second ---)
    local expected
    expected=$(awk 'BEGIN{c=0} /^---$/{c++; if(c==2){found=1; next}} found{print}' "$snap_file")

    # Get Haskell output
    local actual
    actual=$(cabal run iidy-hs -- render "$fixture_path" 2>/dev/null) || {
        echo "FAIL: $fixture_path (render error)"
        ((FAIL++)) || true
        return
    }

    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $fixture_path"
        ((PASS++)) || true
    else
        echo "FAIL: $fixture_path"
        diff <(echo "$expected") <(echo "$actual") | head -20
        echo "---"
        ((FAIL++)) || true
    fi
}

cd "$IIDY_HS"

# Top-level fixtures
for f in "$FIXTURES"/*.yaml; do
    base=$(basename "$f" .yaml)
    snap=$(echo "$base" | tr '-' '_')
    compare_fixture "$f" "$snap"
done

# yaml-iidy-syntax subdirectory
for f in "$FIXTURES"/yaml-iidy-syntax/*.yaml; do
    base=$(basename "$f" .yaml)
    # Skip template files (not standalone)
    if [[ "$base" == *-template ]]; then
        continue
    fi
    snap="yaml_iidy_syntax_$(echo "$base" | tr '-' '_')"
    compare_fixture "$f" "$snap"
done

# custom-resource-templates subdirectory
for f in "$FIXTURES"/custom-resource-templates/*.yaml; do
    base=$(basename "$f" .yaml)
    # Skip template files
    if [[ "$base" == *-template ]]; then
        continue
    fi
    snap="custom_resource_templates_$(echo "$base" | tr '-' '_')"
    compare_fixture "$f" "$snap"
done

echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
echo "TOTAL: $((PASS + FAIL + SKIP))"
