#!/bin/bash
# Capture Fusion launch with +process,+waylanddrv,+win trace + parallel ps.
# Usage: $0 <label>. Reproducer: wait for UI → Show Data Panel → wait 10s → close.

set -euo pipefail

LABEL="${1:-default}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$REPO_DIR/debug/captures/ptree-${LABEL}-${TS}.log"
PSLOG="$REPO_DIR/debug/captures/ptree-${LABEL}-${TS}.ps"

mkdir -p "$(dirname "$LOG")"

echo "[capture-process-tree] LABEL=$LABEL TS=$TS"
echo "[capture-process-tree] LOG=$LOG"
echo "[capture-process-tree] PSLOG=$PSLOG"
echo "[capture-process-tree] QTWEBENGINE_CHROMIUM_FLAGS=${QTWEBENGINE_CHROMIUM_FLAGS:-<unset>}"
echo "[capture-process-tree] QTWEBENGINE_DISABLE_SANDBOX=${QTWEBENGINE_DISABLE_SANDBOX:-<unset>}"
echo "[capture-process-tree] Reproducer:"
echo "[capture-process-tree]   1. Wait for main UI"
echo "[capture-process-tree]   2. Click 'Show Data Panel'"
echo "[capture-process-tree]   3. Wait ~10s for panel to settle"
echo "[capture-process-tree]   4. Close cleanly via X"
echo "[capture-process-tree] Launching in 3s..."
sleep 3

# Background ps snapshotter for spawn-tree reconstruction.
(
    echo "=== ps snapshots (every 2s) for ptree-$LABEL ==="
    while true; do
        date '+--- %Y-%m-%d %H:%M:%S ---'
        ps -eo pid,ppid,lstart,cmd 2>/dev/null \
            | awk 'NR==1 || /wine|Fusion360|QtWebEngine|AdskIdentity|msedgewebview/'
        sleep 2
    done
) > "$PSLOG" 2>&1 &
PS_PID=$!
trap "kill $PS_PID 2>/dev/null || true" EXIT

export WINEDEBUG=+process,+waylanddrv,+win

{
    echo "=== launch-fusion start ==="
    echo "=== TS=$TS LABEL=$LABEL ==="
    echo "=== QTWEBENGINE_CHROMIUM_FLAGS=${QTWEBENGINE_CHROMIUM_FLAGS:-<unset>} ==="
    echo "=== QTWEBENGINE_DISABLE_SANDBOX=${QTWEBENGINE_DISABLE_SANDBOX:-<unset>} ==="
    exec bash "$REPO_DIR/scripts/launch-fusion.sh" 2>&1
} > "$LOG"
