#!/bin/bash
# Run the WebView2 host test app to validate the wine → DComp → Edge WebView2
# presentation chain. Default targets system wine-staging (which ships Zhiyi
# Zhang's DComp implementation, sufficient for WebView2 to render).
#
# Modes (controlled by USE_STAGING env var; default 1):
#
#   USE_STAGING=1  (default)
#       Use SYSTEM wine-staging from /usr/bin (Arch's wine-staging package).
#       Uses its own prefix ~/.wine-staging-test that has been pre-populated
#       with Edge WebView2 runtime + EdgeUpdate registry tree.
#       This is the KNOWN-WORKING configuration that renders content.
#
#   USE_STAGING=0
#       Use the fusion-box-built wine from ~/wine-versions/wine-11.10-fusion/.
#       Targets the Fusion wineprefix ~/.wine-fusion. Currently broken for
#       rendering because mainline wine 11.10 dcomp.dll is a stub
#       (returns E_NOTIMPL). Useful only for A/B testing.
#
# Either mode launches the same webview2_host.exe which navigates to
# test_content.html (canvas animation + CSS 3D transform — forces GPU
# compositing path). If pixels appear, the whole chain works.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$SCRIPT_DIR"

USE_STAGING="${USE_STAGING:-1}"

if [ "$USE_STAGING" = 1 ]; then
    WINE_BIN=/usr/bin/wine
    WINESERVER_BIN=/usr/bin/wineserver
    WINEPREFIX_DEFAULT="$HOME/.wine-staging-test"
    MODE_LABEL="wine-staging (KNOWN WORKING)"
    PATH_PREPEND=/usr/bin:/usr/local/bin
else
    WINE_BIN_DIR="${WINE_BIN_DIR:-$HOME/wine-versions/wine-11.10-fusion/bin}"
    WINE_BIN="$WINE_BIN_DIR/wine"
    WINESERVER_BIN="$WINE_BIN_DIR/wineserver"
    WINEPREFIX_DEFAULT="$HOME/.wine-fusion"
    MODE_LABEL="fusion-box patched wine (mainline base — Data Panel-style failure)"
    PATH_PREPEND="$WINE_BIN_DIR"
fi

export WINESERVER="$WINESERVER_BIN"
export WINEPREFIX="${WINEPREFIX:-$WINEPREFIX_DEFAULT}"
export PATH="$PATH_PREPEND:$PATH"

if [ ! -x "$WINE_BIN" ]; then
    echo "ERROR: wine binary not found at $WINE_BIN" >&2
    exit 1
fi
if [ ! -d "$WINEPREFIX" ]; then
    echo "ERROR: wineprefix $WINEPREFIX not initialized" >&2
    if [ "$USE_STAGING" = 1 ]; then
        echo "(Run setup once: wineboot --init with /usr/bin/wine; copy" >&2
        echo " EdgeWebView runtime + WebView2Loader.dll; import Edge registry tree)" >&2
    fi
    exit 1
fi

WV2_LOADER="$WINEPREFIX/drive_c/Program Files/Autodesk/webdeploy/production/441fa886a8bddbe651a2c8bfe18605e72308757a/Autodesk Identity Manager/WebView2Loader.dll"
if [ ! -f "$WV2_LOADER" ]; then
    echo "ERROR: WebView2Loader.dll not found at:" >&2
    echo "  $WV2_LOADER" >&2
    echo "Make sure Edge WebView2 runtime + Autodesk Identity Manager are present in the prefix." >&2
    exit 1
fi

# Aggressively kill prior wine sessions — same pattern as launch-fusion.sh.
# Without this, wine session-mismatch happens when the same prefix is shared.
echo "[run] mode: $MODE_LABEL"
echo "[run] killing prior wine sessions"
pkill -9 -f webview2_host 2>/dev/null || true
"$WINESERVER_BIN" -k 2>/dev/null || true
for ws in "$HOME"/wine-versions/*/bin/wineserver "$HOME"/wine-versions/*/usr/bin/wineserver; do
    [ -x "$ws" ] && "$ws" -k 2>/dev/null || true
done
sleep 2

# Place WebView2Loader.dll next to our exe (Windows DLL search: exe dir first).
echo "[run] copying WebView2Loader.dll next to exe"
cp -p "$WV2_LOADER" "$SCRIPT_DIR/WebView2Loader.dll"

# Place test_content.html where the navigated file:/// URL expects it.
echo "[run] copying test_content.html into wineprefix drive_c/"
cp -p "$SCRIPT_DIR/test_content.html" "$WINEPREFIX/drive_c/test_content.html"

TS=$(date +%Y%m%d-%H%M%S)
LOG_PREFIX="webview2-test"
[ "$USE_STAGING" = 1 ] && LOG_PREFIX="webview2-staging"
LOG="$REPO_DIR/debug/captures/${LOG_PREFIX}-${TS}.log"
mkdir -p "$(dirname "$LOG")"

echo "[run] LOG=$LOG"
echo "[run] wine: $($WINE_BIN --version 2>&1 | head -1)"
echo "[run] WINEPREFIX=$WINEPREFIX"
echo "[run] launching webview2_host.exe — wait for window, observe content, close X"

export WINEDEBUG="${WINEDEBUG:-+module,+process,fixme-all,err-winediag}"

{
    echo "=== ${LOG_PREFIX} run TS=$TS ==="
    echo "=== mode=${MODE_LABEL} ==="
    echo "=== USE_STAGING=$USE_STAGING WINEDEBUG=$WINEDEBUG WINEPREFIX=$WINEPREFIX ==="
    cd "$SCRIPT_DIR"
    exec "$WINE_BIN" webview2_host.exe 2>&1
} > "$LOG"

echo "[run] done — trace at $LOG"
echo "[run] app log: $WINEPREFIX/drive_c/webview2_host.log"
