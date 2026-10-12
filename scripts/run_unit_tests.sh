#!/bin/bash
#
# Backend-free unit test runner: runs every pure-logic test in
# project/tests/unit/*_smoke_test.gd on a bare Godot headless binary. No
# GDExtension, no darktable build, no RAW fixture. These are the EditStore /
# Library / RejectStore / UiState / Filmstrip tests; they run in CI on every
# push/PR (see .github/workflows/smoke-tests.yml) and locally here.
#
# Globbing project/tests/unit/ is the single source of truth: drop a new
# backend-free *_smoke_test.gd in there and it runs, with no list to update.
#
# Deliberately NOT named "*smoke_test.sh": the pre-commit hook runs every such
# script, and unit tests are CI's job, not the hook's. Keep the name as-is.
#
# Usage:
#   run_unit_tests.sh [GODOT_BIN] [test...]
#
# GODOT_BIN defaults to `godot` on PATH (CI), falling back to the macOS app.
# Trailing args subset the list by name (suffix optional, case-insensitive).
#
# Exit 0 = all PASS. Non-zero = at least one failed (summary printed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$ROOT/project"
OUT_DIR="$PROJECT_DIR/tests/.unit_out"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- locate Godot -------------------------------------------------------------
GODOT_BIN="${1:-}"
if [[ -z "$GODOT_BIN" ]]; then
    if command -v godot >/dev/null 2>&1; then
        GODOT_BIN="$(command -v godot)"
    else
        GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
    fi
fi
[[ -x "$GODOT_BIN" ]] || command -v "$GODOT_BIN" >/dev/null 2>&1 \
    || fail "Godot not found/executable at $GODOT_BIN (pass as arg 1)"
echo "GODOT:      $GODOT_BIN"

# --- pick the test set (glob = source of truth) -------------------------------
TESTS=""
for f in "$PROJECT_DIR"/tests/unit/*_smoke_test.gd; do
    [[ -f "$f" ]] || continue
    TESTS="$TESTS $(basename "$f" _smoke_test.gd)"
done
TESTS="${TESTS# }"
[[ -n "$TESTS" ]] || fail "no unit tests found under $PROJECT_DIR/tests/unit/"
if [[ $# -gt 1 ]]; then
    TESTS=""
    for want in "${@:2}"; do
        want="$(echo "$want" | tr '[:upper:]' '[:lower:]' | sed 's/_smoke_test$//')"
        TESTS="$TESTS $want"
    done
    TESTS="${TESTS# }"
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# --- run each test headless, in parallel -------------------------------------
# Each *_smoke_test.gd prints "<PREFIX>_SMOKE: PASS" and exits 0 on success.
# These tests read-modify-write Godot's user:// (rejects.json / edit records /
# library locations), so each job runs under a private HOME ($OUT_DIR/home.<t>)
# to keep concurrent jobs from clobbering each other's state. A job writes its
# own <t>.log and, on success, a <t>.pass marker the summary reads back.
JOBS="${UNIT_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

run_one() {
    local test="$1"
    local log="$OUT_DIR/$test.log"
    local home="$OUT_DIR/home.$test"
    mkdir -p "$home"
    local status
    HOME="$home" "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
        --script "res://tests/unit/${test}_smoke_test.gd" > "$log" 2>&1
    status=$?
    if [[ $status -eq 0 ]] && grep -q "_SMOKE: PASS" "$log"; then
        : > "$OUT_DIR/$test.pass"
        echo "PASS  $test"
    else
        echo "FAIL  $test  (exit $status, log: $log)"
    fi
}
export -f run_one
export GODOT_BIN PROJECT_DIR OUT_DIR

printf '%s\n' $TESTS | xargs -P"$JOBS" -n1 -I{} bash -c 'run_one "$@"' _ {}

# --- collect per-job results from the .pass markers --------------------------
PASSED=()
FAILED=()
for test in $TESTS; do
    if [[ -f "$OUT_DIR/$test.pass" ]]; then
        PASSED+=("$test")
    else
        FAILED+=("$test")
        grep -E '_SMOKE|_die|SCRIPT ERROR|At: ' "$OUT_DIR/$test.log" 2>/dev/null | head -n 10 || true
    fi
done

echo
echo "== ${#PASSED[@]} passed, ${#FAILED[@]} failed =="
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "FAILED: ${FAILED[*]}"
    exit 1
fi
echo "ALL UNIT TESTS PASS"
