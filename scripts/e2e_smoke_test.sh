#!/bin/bash
#
# End-to-end regression test: loads Main.tscn (the real app scene, not just
# DtBackend), drives every slider + tone curve + crop through their real
# signal handlers, exports a JPEG, and compares it against a committed
# fixture. Catches Main.gd wiring regressions (e.g. a slider refactor binding
# the wrong setter) that scripts/smoke_test.sh and feature_smoke_tests.sh
# cannot see, since those talk to DtBackend directly and never touch Main.gd.
#
# Usage:
#   e2e_smoke_test.sh [RAW_FILE] [DT_BUILD_DIR] [GODOT_BIN] [--update-fixture]
#
# RAW_FILE resolution order: arg 1, then $DT_SMOKE_RAW, then the committed
# fixture project/tests/fixtures/smoke_test.ARW.
#
# --update-fixture (any position) regenerates
# project/tests/fixtures/e2e_fixture.jpg from the current pipeline output
# instead of comparing against it. Use after an intentional rendering change;
# inspect the new fixture before committing it.
#
# Exit 0 = PASS. Non-zero = FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$ROOT/project"
OUT_DIR="$ROOT/scripts/.e2e_out"

UPDATE_FIXTURE=0
POSITIONAL=()
for arg in "$@"; do
    if [[ "$arg" == "--update-fixture" ]]; then
        UPDATE_FIXTURE=1
    else
        POSITIONAL+=("$arg")
    fi
done

DT_BUILD_DIR="${POSITIONAL[1]:-$ROOT/../source/build}"
GODOT_BIN="${POSITIONAL[2]:-/Applications/Godot.app/Contents/MacOS/Godot}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- locate the RAW ----------------------------------------------------------
FIXTURE_RAW="$PROJECT_DIR/tests/fixtures/smoke_test.ARW"
RAW="${POSITIONAL[0]:-${DT_SMOKE_RAW:-}}"
if [[ -z "$RAW" && -f "$FIXTURE_RAW" ]]; then
    RAW="$FIXTURE_RAW"
    echo "Using committed fixture RAW"
fi
[[ -n "$RAW" && -f "$RAW" ]] || fail "no RAW file found; pass one as arg 1 or set DT_SMOKE_RAW"
echo "RAW:        $RAW"

# --- sanity-check the environment --------------------------------------------
[[ -x "$GODOT_BIN" ]] || fail "Godot not executable at $GODOT_BIN (pass as arg 3)"
[[ -d "$DT_BUILD_DIR/bin" ]] || fail "$DT_BUILD_DIR has no bin/ (build darktable first: cd source && ./build.sh)"
DATADIR="$DT_BUILD_DIR/share/darktable"
MODULEDIR="$DT_BUILD_DIR/lib/darktable"
[[ -d "$DATADIR" ]] || fail "datadir missing: $DATADIR"
[[ -d "$MODULEDIR" ]] || fail "moduledir missing: $MODULEDIR"

# Build the GDExtension unconditionally (scons is incremental; a no-op when
# up to date), so the test never runs against a stale framework.
FRAMEWORK="$PROJECT_DIR/bin/libdt_backend.macos.template_debug.framework"
echo "Building GDExtension (scons, incremental)..."
( cd "$ROOT/extension" && scons arch=arm64 target=template_debug ) \
    || fail "scons build failed"
[[ -d "$FRAMEWORK" ]] || fail "scons succeeded but framework missing: $FRAMEWORK"

echo "DT_BUILD:   $DT_BUILD_DIR"
echo "GODOT:      $GODOT_BIN"
echo "OUT_DIR:    $OUT_DIR"
[[ "$UPDATE_FIXTURE" == "1" ]] && echo "MODE:       updating fixture"
echo

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export DT_BACKEND_DATADIR="$DATADIR"
export DT_BACKEND_MODULEDIR="$MODULEDIR"

echo "=== Running e2e smoke test (Main.tscn, full UI path) ==="
LOG="$OUT_DIR/godot.log"
set +e
if [[ "$UPDATE_FIXTURE" == "1" ]]; then
    "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
        --script res://tests/e2e_smoke_test.gd \
        -- "$RAW" "$OUT_DIR" "--update-fixture" > "$LOG" 2>&1
else
    "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
        --script res://tests/e2e_smoke_test.gd \
        -- "$RAW" "$OUT_DIR" > "$LOG" 2>&1
fi
GODOT_STATUS=$?
set -e

grep -Ev 'Luxe\.app|gdextension_(library_loader|manager)|gdextension\.cpp' "$LOG" \
    | grep -E 'E2E_SMOKE|DtBackend|Godot Engine' || true

grep -q "E2E_SMOKE_RESULT: PASS" "$LOG" || fail "see $LOG"

if [[ "$UPDATE_FIXTURE" == "1" ]]; then
    echo
    echo "PASS: fixture updated at $PROJECT_DIR/tests/fixtures/e2e_fixture.jpg"
    echo "Review the new fixture, then commit it."
else
    echo
    echo "PASS: output matched project/tests/fixtures/e2e_fixture.jpg"
fi
exit 0
