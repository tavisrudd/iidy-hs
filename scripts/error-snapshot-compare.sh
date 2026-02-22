#!/usr/bin/env bash
# Compare Haskell error output against Rust error snapshots
set -uo pipefail

RUST_SNAPS="$HOME/src/iidy/tests/snapshots"
PROJECT="$HOME/src/iidy-hs"
FIXTURES="$PROJECT/test-fixtures/example-templates/errors"
PASS=0
FAIL=0
SKIP=0
UNEXP=0

for f in "$FIXTURES"/*.yaml; do
    base=$(basename "$f" .yaml)
    snap=$(echo "$base" | tr '-' '_')
    snap_file="$RUST_SNAPS/error_examples_snapshots__auto_discovered_example_templates_errors_${snap}.snap"

    if [ ! -f "$snap_file" ]; then
        echo "SKIP: $base"
        SKIP=$((SKIP+1))
        continue
    fi

    expected=$(awk 'BEGIN{c=0} /^---$/{c++; if(c==2){found=1; next}} found{print}' "$snap_file")

    # Run from test-fixtures/ so paths match Rust's relative format
    rel_path="example-templates/errors/${base}.yaml"
    actual=$(cd "$PROJECT/test-fixtures" && cabal -v0 --project-dir="$PROJECT" run iidy-hs -- render "$rel_path" 2>&1)
    rc=$?

    if [ $rc -eq 0 ]; then
        echo "UNEXPECTED_OK: $base"
        UNEXP=$((UNEXP+1))
        continue
    fi

    if [ "$expected" = "$actual" ]; then
        echo "PASS: $base"
        PASS=$((PASS+1))
    else
        echo "FAIL: $base"
        diff <(echo "$expected") <(echo "$actual") | head -8
        echo "---"
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP  UNEXPECTED_OK: $UNEXP"
