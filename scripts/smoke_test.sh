#!/bin/bash
#
# Functional smoke test: RAW -> two EV values -> two different-content PNGs,
# rendered through the real DtBackend GDExtension (Godot headless). This is the
# shared acceptance oracle: run it to capture a "before" baseline now, and re-run it after the GTK-free work to
# prove the pipeline still produces correct, parameter-sensitive output. A
# broken IOP .so (loads but can't resolve a symbol mid-render) fails here and
# nowhere else in the audit chain.
#
# It does NOT build a full .app export (slow: rebuild
# framework + bundle ~191 dylibs + resign) which can't be functionally verified
# headless anyway. This test exercises the same darktable pipeline the .app would,
# via the already-built debug framework, in seconds.
#
# Usage:
#   smoke_test.sh [RAW_FILE] [DT_BUILD_DIR] [OUT_DIR] [GODOT_BIN]
#
# All args optional; defaults assume this repo's standard layout. RAW_FILE resolves
# in order: arg 1, then $DT_SMOKE_RAW, then the committed fixture
# project/tests/fixtures/smoke_test.ARW (so every run tests the same image),
# then auto-discovery under ~/Pictures/Darktable and ~/Downloads.
#
# Exit 0 = PASS (both PNGs written, valid, and different content). Non-zero = FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_DIR="$ROOT/project"
# The darktable build lives in the outer repo (godot-poc's parent).
DT_BUILD_DIR="${2:-$ROOT/../source/build}"
OUT_DIR="${3:-$ROOT/scripts/.smoke_out}"
GODOT_BIN="${4:-/Applications/Godot.app/Contents/MacOS/Godot}"

# Two EV values far enough apart that a working exposure module must produce
# visibly different pixels (and thus different file bytes).
EV1="${DT_SMOKE_EV1:-0.0}"
EV2="${DT_SMOKE_EV2:-2.0}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- locate the RAW ---------------------------------------------------------
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

# --- sanity-check the environment ------------------------------------------
[[ -x "$GODOT_BIN" ]] || fail "Godot not executable at $GODOT_BIN (pass as arg 4)"
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
echo "OUT_DIR:    $OUT_DIR"
echo "EVs:        $EV1, $EV2"
echo

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# --- run the pipeline through DtBackend, headless ---------------------------
# The backend reads these from the real process env (getenv in compute_dt_dirs);
# Main.gd's editor-only helper does not run for a --script invocation, so we set
# them here explicitly.
export DT_BACKEND_DATADIR="$DATADIR"
export DT_BACKEND_MODULEDIR="$MODULEDIR"

echo "=== Rendering (RAW -> EV $EV1 / EV $EV2 -> PNG) ==="
LOG="$OUT_DIR/godot.log"
set +e
"$GODOT_BIN" --headless --path "$PROJECT_DIR" \
    --script res://tests/smoke_test.gd \
    -- "$RAW" "$OUT_DIR" "$EV1" "$EV2" > "$LOG" 2>&1
GODOT_STATUS=$?
set -e

# Show the meaningful lines; suppress the benign GDExtension-scan errors Godot
# emits from stray .gdextension copies inside project/Luxe.app (the exported
# bundle committed into the project tree). The real extension still loads -- if
# it did not, init would fail below. Full output is in $LOG.
grep -Ev 'Luxe\.app|gdextension_(library_loader|manager)|gdextension\.cpp' "$LOG" \
    | grep -E 'SMOKE|DtBackend|Godot Engine' || true

grep -q "SMOKE_RESULT: PASS" "$LOG" || fail "backend reported failure (see $LOG)"

# --- assert on the outputs --------------------------------------------------
# (plain read loop, not `mapfile`: macOS ships bash 3.2, which lacks mapfile)
FILES=()
while IFS= read -r line; do
    FILES+=("$line")
done < <(grep '^SMOKE_FILE: ' "$LOG" | sed 's/^SMOKE_FILE: //')
[[ ${#FILES[@]} -eq 2 ]] || fail "expected 2 output PNGs, backend reported ${#FILES[@]}"

for f in "${FILES[@]}"; do
    [[ -s "$f" ]] || fail "output missing or empty: $f"
    # PNG magic: first 8 bytes are 89 50 4E 47 0D 0A 1A 0A
    sig="$(head -c 8 "$f" | xxd -p)"
    [[ "$sig" == "89504e470d0a1a0a" ]] || fail "not a valid PNG (bad signature): $f"
    echo "  ok: $f ($(wc -c < "$f" | tr -d ' ') bytes)"
done

# Different EVs must yield different content. Byte-identical outputs mean the
# exposure param never reached the pipeline (the exact failure a broken/guarded
# module would show).
H1="$(shasum -a 256 "${FILES[0]}" | awk '{print $1}')"
H2="$(shasum -a 256 "${FILES[1]}" | awk '{print $1}')"
[[ "$H1" != "$H2" ]] || fail "the two PNGs are byte-identical -> exposure had no effect (broken pipeline?)"

echo
echo "PASS: 2 valid, content-different PNGs written to $OUT_DIR"
echo "  ${FILES[0]}"
echo "  ${FILES[1]}"
exit 0
