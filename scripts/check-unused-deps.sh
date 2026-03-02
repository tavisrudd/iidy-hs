#!/usr/bin/env bash
# scripts/check-unused-deps.sh
# Checks for unused dependencies in iidy-hs.cabal by analyzing source imports.
#
# For each build-depends entry in each cabal component (library, executable,
# test-suite), determines whether any source file in that component's source
# directories imports a module from that package. Reports any deps where no
# imports are found.
#
# Exit code: 0 if no unused deps found, 1 if any unused deps found.
set -euo pipefail

CABAL_FILE="iidy-hs.cabal"
SRC_DIRS_LIB="src"
SRC_DIRS_EXE="app"
SRC_DIRS_TEST="test"

# Mapping from cabal package name to a shell-regex of module prefixes.
# A dep is considered "used" if any source file in its component contains
# an import matching one of these prefixes.
#
# Format: declare each package on its own line as:
#   PKGMAP["pkg-name"]="Prefix1|Prefix2"
#
# For packages provided by GHC itself (base, ghc-prim, etc.) we skip them
# since they're always needed. We also skip the library's own package name
# used in the exe and test components.
declare -A PKGMAP
PKGMAP["aeson"]="Data\.Aeson"
PKGMAP["aeson-pretty"]="Data\.Aeson\.Encode\.Pretty"
PKGMAP["amazonka"]="^import.*Amazonka[^.]|^import.*Amazonka\.Auth|^import.*Amazonka\.Data|^import.*Amazonka\.Types"
PKGMAP["amazonka-cloudformation"]="Amazonka\.CloudFormation"
PKGMAP["amazonka-s3"]="Amazonka\.S3"
PKGMAP["amazonka-sns"]="Amazonka\.SNS"
PKGMAP["amazonka-ssm"]="Amazonka\.SSM"
PKGMAP["amazonka-sts"]="Amazonka\.STS"
PKGMAP["ansi-terminal"]="System\.Console\.ANSI"
PKGMAP["async"]="Control\.Concurrent\.Async"
PKGMAP["bytestring"]="Data\.ByteString"
PKGMAP["conduit"]="Data\.Conduit"
PKGMAP["containers"]="Data\.Map|Data\.Set|Data\.Sequence|Data\.IntMap|Data\.IntSet"
PKGMAP["crypton"]="Crypto\."
PKGMAP["directory"]="System\.Directory"
PKGMAP["filepath"]="System\.FilePath"
PKGMAP["HsYAML"]="Data\.YAML"
PKGMAP["http-client"]="Network\.HTTP\.Client"
PKGMAP["http-conduit"]="Network\.HTTP\.Simple|Network\.HTTP\.Conduit"
PKGMAP["http-types"]="Network\.HTTP\.Types"
PKGMAP["memory"]="Data\.ByteArray"
PKGMAP["microlens"]="Lens\.Micro"
PKGMAP["network"]="Network\.Socket|Network\.BSD"
PKGMAP["optparse-applicative"]="Options\.Applicative"
PKGMAP["prettyprinter"]="Prettyprinter"
PKGMAP["process"]="System\.Process"
PKGMAP["QuickCheck"]="Test\.QuickCheck"
PKGMAP["random"]="System\.Random"
PKGMAP["regex-tdfa"]="Text\.Regex\.TDFA"
PKGMAP["resourcet"]="Control\.Monad\.Trans\.Resource"
PKGMAP["scientific"]="Data\.Scientific"
PKGMAP["stm"]="Control\.Concurrent\.STM|Control\.Monad\.STM"
PKGMAP["tasty"]="Test\.Tasty[^.]"
PKGMAP["tasty-hunit"]="Test\.Tasty\.HUnit"
PKGMAP["tasty-quickcheck"]="Test\.Tasty\.QuickCheck"
PKGMAP["temporary"]="System\.IO\.Temp"
PKGMAP["terminal-size"]="System\.Console\.Terminal\.Size"
PKGMAP["text"]="Data\.Text"
PKGMAP["time"]="Data\.Time"
PKGMAP["transformers"]="Control\.Monad\.Trans\."
PKGMAP["unix"]="System\.Posix"
PKGMAP["uuid"]="Data\.UUID"
PKGMAP["vector"]="Data\.Vector"

# Packages to always skip (GHC boot libs, or internal component refs)
ALWAYS_SKIP=("base" "iidy-hs" "ghc-prim" "integer-gmp" "integer-simple" "rts" "amazonka-core")

# Check if a package should be skipped
should_skip() {
    local pkg="$1"
    for skip in "${ALWAYS_SKIP[@]}"; do
        if [[ "$pkg" == "$skip" ]]; then
            return 0
        fi
    done
    return 1
}

# Extract build-depends packages from a named component in the cabal file.
# Handles multi-line build-depends blocks.
# Args: $1 = cabal file, $2 = component type (library|executable|test-suite)
#       $3 = component name (empty for library)
extract_deps() {
    local cabal="$1"
    local comp_type="$2"
    local comp_name="${3:-}"

    python3 - "$cabal" "$comp_type" "$comp_name" <<'EOF'
import sys
import re

cabal_file = sys.argv[1]
comp_type = sys.argv[2]
comp_name = sys.argv[3]

with open(cabal_file) as f:
    content = f.read()

# Find the start of the component
if comp_type == "library":
    pattern = r'^library\s*$'
elif comp_name:
    pattern = rf'^{comp_type}\s+{re.escape(comp_name)}\s*$'
else:
    pattern = rf'^{comp_type}\s*$'

lines = content.split('\n')
start = None
for i, line in enumerate(lines):
    if re.match(pattern, line, re.IGNORECASE):
        start = i
        break

if start is None:
    sys.exit(0)

# Find the build-depends block within this component
in_build_depends = False
deps = []
for i in range(start + 1, len(lines)):
    line = lines[i]
    # New top-level component starts (non-indented, non-empty line)
    if i > start + 1 and line and line[0] not in (' ', '\t') and not line.startswith('--'):
        break
    stripped = line.strip()
    if not stripped or stripped.startswith('--'):
        continue
    if re.match(r'^build-depends\s*:', stripped, re.IGNORECASE):
        in_build_depends = True
        # Extract packages after the colon
        rest = re.sub(r'^build-depends\s*:\s*', '', stripped, flags=re.IGNORECASE)
        for pkg in re.split(r'[,\n]', rest):
            pkg = pkg.strip()
            if pkg:
                # Remove version constraints: take just the name
                name = re.split(r'[\s>=<!]', pkg)[0].strip()
                if name:
                    deps.append(name)
        continue
    if in_build_depends:
        # Check if we've left the build-depends block (new field)
        if re.match(r'^[a-z]', stripped) and ':' in stripped:
            in_build_depends = False
            continue
        # continuation of build-depends
        for pkg in re.split(r'[,]', stripped):
            pkg = pkg.strip()
            if pkg:
                name = re.split(r'[\s>=<!]', pkg)[0].strip()
                if name:
                    deps.append(name)

for d in deps:
    print(d)
EOF
}

# Check if any file in the given dirs imports a module matching the pattern.
# Args: $1 = space-separated list of dirs, $2 = egrep pattern
has_import() {
    local dirs="$1"
    local pattern="$2"
    # shellcheck disable=SC2086
    if grep -rqE "$pattern" $dirs --include="*.hs" 2>/dev/null; then
        return 0
    fi
    return 1
}

check_component() {
    local label="$1"
    local dirs="$2"
    local comp_type="$3"
    local comp_name="${4:-}"

    local unused=()
    local unknown=()

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        if should_skip "$pkg"; then
            continue
        fi
        if [[ -v PKGMAP["$pkg"] ]]; then
            pattern="${PKGMAP[$pkg]}"
            if ! has_import "$dirs" "$pattern"; then
                unused+=("$pkg")
            fi
        else
            unknown+=("$pkg")
        fi
    done < <(extract_deps "$CABAL_FILE" "$comp_type" "$comp_name")

    if [[ ${#unknown[@]} -gt 0 ]]; then
        echo "  WARNING: No module mapping for (check manually): ${unknown[*]}"
    fi
    if [[ ${#unused[@]} -gt 0 ]]; then
        echo "  UNUSED in $label: ${unused[*]}"
        return 1
    fi
    return 0
}

echo "=== Checking unused dependencies in $CABAL_FILE ==="
echo ""

failed=0

echo "[library]"
if ! check_component "library" "$SRC_DIRS_LIB" "library" ""; then
    failed=1
fi
echo ""

echo "[executable iidy-hs]"
if ! check_component "executable" "$SRC_DIRS_EXE $SRC_DIRS_LIB" "executable" "iidy-hs"; then
    failed=1
fi
echo ""

echo "[test-suite iidy-hs-test]"
if ! check_component "test-suite" "$SRC_DIRS_TEST $SRC_DIRS_LIB" "test-suite" "iidy-hs-test"; then
    failed=1
fi
echo ""

if [[ $failed -eq 0 ]]; then
    echo "OK — no unused dependencies detected."
else
    echo "FAIL — unused dependencies found. Remove them from $CABAL_FILE."
    exit 1
fi
