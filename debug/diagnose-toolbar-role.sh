#!/bin/bash
# Probe the toolbar's wayland role for docs/bottom-toolbar-burial.md.
# Produces $OUT_DIR/{probe-windows.txt, wayland-trace.log}.
# Usage: $0 [probe|trace|both]  (default: both).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${DIAG_OUT_DIR:-$REPO_DIR/debug/captures}"
PROBE_SRC="$REPO_DIR/debug/wine-tests/probe-windows.c"
PROBE_BIN="$REPO_DIR/debug/wine-tests/probe-windows.exe.so"
PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"

PATCHED_WINE="$HOME/wine-versions/wine-11.10-fusion/bin/wine"
if [ -n "${WINE_BIN:-}" ]; then :
elif [ -x "$PATCHED_WINE" ]; then WINE_BIN="$PATCHED_WINE"
else WINE_BIN=wine; fi

export WINEPREFIX="$PREFIX"
export WINEARCH=win64

mkdir -p "$OUT_DIR"

log() { echo "[$(date +%H:%M:%S)] $*"; }

build_probe() {
    if [ -f "$PROBE_BIN" ] && [ "$PROBE_BIN" -nt "$PROBE_SRC" ]; then return; fi
    log "building probe-windows..."
    (cd "$REPO_DIR/debug/wine-tests" && winegcc -m64 "$PROBE_SRC" -o "$PROBE_BIN" >/dev/null 2>&1)
}

run_probe() {
    build_probe
    local out="$OUT_DIR/probe-windows.txt"
    log "running probe-windows -> $out"
    "$WINE_BIN" "$PROBE_BIN" > "$out" 2>&1 || true
    log "probe lines for the toolbar class:"
    grep -A 6 "Qt683QWindowToolSaveBits" "$out" | head -40 || true
}

trace_launch() {
    local out="$OUT_DIR/wayland-trace.log"
    log "launching Fusion with WINEDEBUG=+waylanddrv -> $out (kills prior session)"
    WINEDEBUG="+waylanddrv,fixme-all,err-winediag" \
    FUSION_PREWARM_IDM=1 bash "$REPO_DIR/scripts/launch-fusion.sh" > "$out" 2>&1 &
    LAUNCH_PID=$!
    log "Fusion launching in background as PID $LAUNCH_PID; tailing trace..."
}

cmd="${1:-both}"
case "$cmd" in
    probe)
        run_probe
        ;;
    trace)
        trace_launch
        log "Fusion is running under +wayland trace. Output is being written to:"
        log "  $OUT_DIR/wayland-trace.log"
        log "Stop with: kill $LAUNCH_PID && wineserver -k"
        ;;
    both)
        trace_launch
        WAIT_SECS="${WAIT_SECS:-45}"
        log "waiting ${WAIT_SECS}s for Fusion to load past splash / sign-in..."
        sleep "$WAIT_SECS"
        run_probe
        log "tearing down Fusion launch (PID $LAUNCH_PID)..."
        kill "$LAUNCH_PID" 2>/dev/null || true
        wineserver -k 2>/dev/null || true
        sleep 2
        log "done. Artifacts:"
        log "  $OUT_DIR/probe-windows.txt"
        log "  $OUT_DIR/wayland-trace.log"
        log ""
        log "Useful greps:"
        log "  grep -n 'role=' $OUT_DIR/wayland-trace.log | head"
        log "  grep -n 'make_subsurface\\|make_toplevel\\|make_popup' $OUT_DIR/wayland-trace.log | head"
        log "  grep -n '<TOOLBAR_HWND>' $OUT_DIR/wayland-trace.log"
        ;;
    *)
        echo "usage: $0 [probe|trace|both]" >&2
        exit 1
        ;;
esac
