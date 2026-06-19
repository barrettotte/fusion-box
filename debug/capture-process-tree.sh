#!/bin/bash
# Capture Fusion launch with full process-creation visibility + parallel
# OS-level process-tree snapshots. Used to settle whether Qt6WebEngineCore
# actually honors --single-process, by comparing the spawned wine subprocess
# tree (and their commandlines) with and without the flag.
#
# Outputs (under debug/captures/):
#   ptree-<label>-<ts>.log    - wine trace with +process,+waylanddrv,+win
#   ptree-<label>-<ts>.ps     - periodic ps snapshots of wine processes
#
# Usage:
#   bash debug/capture-process-tree.sh baseline
#   QTWEBENGINE_CHROMIUM_FLAGS="--single-process --no-sandbox" \
#     QTWEBENGINE_DISABLE_SANDBOX=1 \
#     bash debug/capture-process-tree.sh sp
#
# Then diff the two captures to see which subprocesses --single-process
# actually suppressed.
#
# Reproducer:
#   1. Wait for main UI
#   2. Click 'Show Data Panel' (triggers QtWebEngineProcess spawn)
#   3. Wait ~10s for the panel to settle
#   4. Close cleanly via X

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

# Background ps snapshotter. Captures wine processes every 2s with full
# commandline (args after the executable name), parent PID, and start time
# so we can reconstruct the spawn tree. Writes to $PSLOG until killed.
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

# Wine trace with process creation, wayland, and window-system channels.
# +process logs every CreateProcess call with executable + argv - this is
# the direct evidence of which wine subprocesses got spawned and what
# command line they got (e.g., --type=renderer, --single-process, ...).
export WINEDEBUG=+process,+waylanddrv,+win

{
    echo "=== launch-fusion start ==="
    echo "=== TS=$TS LABEL=$LABEL ==="
    echo "=== QTWEBENGINE_CHROMIUM_FLAGS=${QTWEBENGINE_CHROMIUM_FLAGS:-<unset>} ==="
    echo "=== QTWEBENGINE_DISABLE_SANDBOX=${QTWEBENGINE_DISABLE_SANDBOX:-<unset>} ==="
    exec bash "$REPO_DIR/scripts/launch-fusion.sh" 2>&1
} > "$LOG"
