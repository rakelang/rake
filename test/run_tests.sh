#!/bin/bash
# test/run_tests.sh
#
# End-to-end test script for Rake compiler.
# Compiles Rake -> MLIR -> LLVM IR -> Object files.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Output directory for generated files
OUT_DIR="${PROJECT_ROOT}/test/out"
mkdir -p "$OUT_DIR"

echo "=== Rake End-to-End Test Suite ==="
echo ""

# Check for required tools
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 not found in PATH${NC}"
        echo "Please install MLIR/LLVM tools"
        exit 1
    fi
}

check_tool mlir-opt
check_tool mlir-translate
check_tool llc

# Check for Rake compiler
RAKE="${PROJECT_ROOT}/_build/default/bin/main.exe"
if [ ! -f "$RAKE" ]; then
    RAKE="${PROJECT_ROOT}/rake"
    if [ ! -f "$RAKE" ]; then
        echo -e "${YELLOW}Warning: Rake compiler not found. Run 'dune build' first.${NC}"
        echo "Looking for: ${PROJECT_ROOT}/_build/default/bin/main.exe"
        echo ""
    fi
fi

# Test a single .rk file
test_file() {
    local rk="$1"
    local basename="$(basename "${rk%.rk}")"
    local outbase="${OUT_DIR}/${basename}"

    echo -n "Testing ${basename}... "

    # Step 1: Compile Rake -> MLIR
    if [ -f "$RAKE" ]; then
        if ! "$RAKE" --emit-mlir "$rk" > "${outbase}.mlir" 2>&1; then
            echo -e "${RED}FAIL${NC} (Rake compilation failed)"
            cat "${outbase}.mlir"
            ((FAILED++))
            return 1
        fi
    else
        echo -e "${YELLOW}SKIP${NC} (no compiler)"
        ((SKIPPED++))
        return 0
    fi

    # Step 2: Lower MLIR to LLVM dialect
    if ! mlir-opt "${outbase}.mlir" \
        --convert-scf-to-cf \
        --convert-vector-to-llvm \
        --convert-func-to-llvm \
        --convert-arith-to-llvm \
        --reconcile-unrealized-casts \
        -o "${outbase}.llvm.mlir" 2>&1; then
        echo -e "${RED}FAIL${NC} (MLIR lowering failed)"
        ((FAILED++))
        return 1
    fi

    # Step 3: Translate to LLVM IR
    if ! mlir-translate --mlir-to-llvmir "${outbase}.llvm.mlir" -o "${outbase}.ll" 2>&1; then
        echo -e "${RED}FAIL${NC} (LLVM IR translation failed)"
        ((FAILED++))
        return 1
    fi

    # Step 4: Compile to object file
    if ! llc -filetype=obj "${outbase}.ll" -o "${outbase}.o" 2>&1; then
        echo -e "${RED}FAIL${NC} (Object compilation failed)"
        ((FAILED++))
        return 1
    fi

    echo -e "${GREEN}PASS${NC}"
    echo "  Generated: ${outbase}.o"
    ((PASSED++))
    return 0
}

# Parse-only test (for syntax validation without full compilation)
parse_test() {
    local rk="$1"
    local basename="$(basename "${rk%.rk}")"

    echo -n "Parsing ${basename}... "

    if [ -f "$RAKE" ]; then
        if "$RAKE" --parse-only "$rk" 2>&1; then
            echo -e "${GREEN}PASS${NC}"
            ((PASSED++))
            return 0
        else
            echo -e "${RED}FAIL${NC}"
            ((FAILED++))
            return 1
        fi
    else
        echo -e "${YELLOW}SKIP${NC} (no compiler)"
        ((SKIPPED++))
        return 0
    fi
}

# Run tests on test/ directory
echo "--- Test Files ---"
for rk in "${SCRIPT_DIR}"/*.rk; do
    if [ -f "$rk" ]; then
        parse_test "$rk"
    fi
done

# Also run tests on examples/ if they exist
if [ -d "${PROJECT_ROOT}/examples" ]; then
    echo ""
    echo "--- Example Files ---"
    for rk in "${PROJECT_ROOT}/examples"/*.rk; do
        if [ -f "$rk" ]; then
            parse_test "$rk"
        fi
    done
fi

echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"
echo -e "Skipped: ${YELLOW}${SKIPPED}${NC}"

if [ $FAILED -gt 0 ]; then
    exit 1
else
    exit 0
fi
