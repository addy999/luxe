#!/bin/bash
#
# Feature-level smoke test runner: runs every per-feature test in
# project/tests/*_smoke_test.gd headless through the real DtBackend
# GDExtension, same environment contract as smoke_test.sh (which stays the
# pipeline-level oracle for RAW -> PNG output; this script covers the
# per-slider feature assertions).
#
# Usage:
#   feature_smoke_tests.sh [RAW_FILE] [DT_BUILD_DIR] [GODOT_BIN] [test...]
#
# All args optional; defaults assume this repo's standard layout. RAW_FILE
# resolves in order: arg 1, then $DT_SMOKE_RAW, then the committed fixture
# project/tests/fixtures/smoke_test.ARW, then auto-discovery under
# ~/Pictures/Darktable and ~/Downloads (same order as smoke_test.sh).
#
# Optional trailing "test..." names (e.g. dehaze crop) run a subset; the name
# matches the .gd filename with the _smoke_test.gd suffix optional and is
# case-insensitive.
#
# Exit 0 = all tests PASS. Non-zero = at least one failed (summary printed).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="$ROOT/project"
# The darktable build lives in the outer repo (godot-poc's parent).
DT_BUILD_DIR="${2:-$ROOT/../source/build}"
GODOT_BIN="${3:-/Applications/Godot.app/Contents/MacOS/Godot}"
OUT_DIR="$PROJECT_DIR/tests/.feature_out"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- locate the RAW (same resolution order as smoke_test.sh) -----------------
FIXTURE="$PROJECT_DIR/tests/fixtures/smoke_test.ARW"
RAW="${1:-${DT_SMOKE_RAW:-}}"
if [[ -z "$RAW" && -f "$FIXTURE" ]]; then
    RAW="$FIXTURE"
    echo "Using committed fixture RAW"
fi
if [[ -z "$RAW" ]]; then
    echo "No RAW given and no fixture; auto-discovering..."
    RAW="$(find "$HOME/Pictures/Darktable" "$HOME/Downloads" \
             \( -iname '*.arw' -o -iname '*.cr2' -o -iname '*.nef' \
                -o -iname '*.dng' -o -iname '*.raf' -o -iname '*.orf' \) \
             2>/dev/null | head -n1 || true)"
fi
[[ -n "$RAW" && -f "$RAW" ]] || fail "no RAW file found; pass one as arg 1 or set DT_SMOKE_RAW"
echo "RAW:        $RAW"

# --- sanity-check the environment (same as smoke_test.sh) --------------------
[[ -x "$GODOT_BIN" ]] || fail "Godot not executable at $GODOT_BIN (pass as arg 3)"
[[ -d "$DT_BUILD_DIR/bin" ]] || fail "$DT_BUILD_DIR has no bin/ (build darktable first: cd source && ./build.sh)"
DATADIR="$DT_BUILD_DIR/share/darktable"
MODULEDIR="$DT_BUILD_DIR/lib/darktable"
[[ -d "$DATADIR" ]] || fail "datadir missing: $DATADIR"
[[ -d "$MODULEDIR" ]] || fail "moduledir missing: $MODULEDIR"

# Build the GDExtension unconditionally before testing (scons is incremental;
# a no-op when up to date). Building always guarantees the tests never run
# against a stale framework from an older source tree.
FRAMEWORK="$PROJECT_DIR/bin/libdt_backend.macos.template_debug.framework"
echo "Building GDExtension (scons, incremental)..."
( cd "$ROOT/extension" && scons arch=arm64 target=template_debug ) \
    || fail "scons build failed"
[[ -d "$FRAMEWORK" ]] || fail "scons succeeded but framework missing: $FRAMEWORK"

echo "DT_BUILD:   $DT_BUILD_DIR"
echo "GODOT:      $GODOT_BIN"
echo

# --- pick the test set --------------------------------------------------------
# All per-feature tests (everything except the pipeline-level smoke_test.gd,
# which smoke_test.sh already owns). Trailing args subset the list.
TESTS="blacks_whites contrast crop dehaze saturation shadows_highlights tonecurve vibrance white_balance"
if [[ $# -gt 3 ]]; then
    TESTS=""
    for want in "${@:4}"; do
        want="$(echo "$want" | tr '[:upper:]' '[:lower:]' | sed 's/_smoke_test$//')"
        TESTS="$TESTS $want"
    done
    TESTS="${TESTS# }"
fi

# The backend reads these from the real process env (getenv in compute_dt_dirs);
# set them here explicitly, same as smoke_test.sh.
export DT_BACKEND_DATADIR="$DATADIR"
export DT_BACKEND_MODULEDIR="$MODULEDIR"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# --- run each feature test headless ------------------------------------------
# Each *_smoke_test.gd prints "<PREFIX>_SMOKE: PASS" and exits 0 on success;
# _die() prints a diagnostic and exits 1. crop additionally needs an out_dir.
PASSED=()
FAILED=()
for test in $TESTS; do
    LOG="$OUT_DIR/$test.log"
    set +e
    if [[ "$test" == "crop" ]]; then
        "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
            --script "res://tests/${test}_smoke_test.gd" \
            -- "$RAW" "$OUT_DIR" > "$LOG" 2>&1
    else
        "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
            --script "res://tests/${test}_smoke_test.gd" \
            -- "$RAW" > "$LOG" 2>&1
    fi
    STATUS=$?
    set -e

    if [[ $STATUS -eq 0 ]] && grep -q "_SMOKE: PASS" "$LOG"; then
        PASSED+=("$test")
        echo "PASS  $test"
    else
        FAILED+=("$test")
        echo "FAIL  $test  (exit $STATUS, log: $LOG)"
        # Show the test's own diagnostic lines, skip Godot's engine noise.
        grep -E '_SMOKE|_die|SCRIPT ERROR|At: ' "$LOG" | head -n 10 || true
    fi
done

# --- summary ------------------------------------------------------------------
echo
echo "== ${#PASSED[@]} passed, ${#FAILED[@]} failed =="
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "FAILED: ${FAILED[*]}"
    exit 1
fi
echo "ALL FEATURE SMOKE TESTS PASS"
