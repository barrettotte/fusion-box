#!/bin/bash
# Launch Autodesk Fusion 360 from the fusion-box wineprefix.

set -euo pipefail

PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:-fixme-all,err-winediag}"

# Kill any prior session — Fusion refuses to run a second instance, and
# WebView2/CER children survive a plain wineserver -k in a detached tree.
pkill -9 -f cer_dialog 2>/dev/null || true
pkill -9 -f msedgewebview2 2>/dev/null || true
pkill -9 -f Fusion360.exe 2>/dev/null || true
pkill -9 -f AdskIdentityManager.exe 2>/dev/null || true

wineserver -k 2>/dev/null || true
for ws in "$HOME"/wine-versions/*/bin/wineserver "$HOME"/wine-versions/*/usr/bin/wineserver; do
    [ -x "$ws" ] && "$ws" -k 2>/dev/null || true
done
sleep 2

# WINEDLLOVERRIDES:
#   bcp47langs=       — IDM's GetUserLanguages import is unimplemented; without
#                       this override wine aborts before IDM inits.
#   winewayland.drv=b — native Wayland driver (XWayland renders Qt6 as black).
#                       FUSION_FORCE_X11=1 falls back for diagnostics.
DRIVER_OVERRIDE='winewayland.drv=b;winex11.drv='
if [ "${FUSION_FORCE_X11:-0}" = 1 ]; then
    DRIVER_OVERRIDE='winewayland.drv=;winex11.drv=b'
fi
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}${DRIVER_OVERRIDE:+$DRIVER_OVERRIDE;}bcp47langs="

# Wine binary: $WINE_BIN > patched build from build-wine.sh > system wine.
PATCHED_WINE="$HOME/wine-versions/wine-11.10-fusion/bin/wine"
if [ -n "${WINE_BIN:-}" ]; then
    :
elif [ -x "$PATCHED_WINE" ]; then
    WINE_BIN="$PATCHED_WINE"
else
    WINE_BIN="wine"
fi

# winebrowser needs $BROWSER set — its default /usr/bin/<browser> paths don't
# exist in this image, so IDM's OAuth redirect silently fails without this.
export BROWSER=/usr/local/bin/xdg-open

# Force Qt6 to 1:1 pixel scale. Wine's multi-monitor DPI handling breaks
# Qt's hover-driven cursor-shape updates when auto-scaling per screen.
export QT_ENABLE_HIGHDPI_SCALING=0
export QT_AUTO_SCREEN_SCALE_FACTOR=0
export QT_SCALE_FACTOR=1

# Disable Qt's 4ms paint-coalescing idle. On a secondary monitor Fusion
# quiesces after ~6 parent commits — with the default idle, patch 0006's
# vsub can miss the toolbar merge and stay black. See navbar-black-secondary-monitor.
export QT_QPA_UPDATE_IDLE_TIME=0

# FUSION_QTWE_SINGLE_PROCESS=1: diagnostic — collapse Qt6WebEngine into one
# process so patch 0006's cross-process HWND lookup succeeds (Data Panel).
if [ "${FUSION_QTWE_SINGLE_PROCESS:-0}" = 1 ]; then
    export QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:-} --single-process"
fi

# WebView2 fallbacks (kept for historical Data Panel investigation — see
# project_data_panel_investigation memory. Not needed since the fresh-prefix fix).
if [ "${FUSION_WEBVIEW2_DISABLE_DCOMP:-0}" = 1 ]; then
    export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:-} --disable-direct-composition"
fi
if [ "${FUSION_WEBVIEW2_FORCE_SW:-0}" = 1 ]; then
    export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:-} --disable-direct-composition --disable-gpu --disable-gpu-compositing --use-gl=swiftshader"
fi

# Most-recent Fusion360.exe (auto-update lands versions as sibling hash dirs).
FUSION_EXE=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production" \
    -name Fusion360.exe -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$FUSION_EXE" ]; then
    echo "ERROR: Fusion360.exe not found under $PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"
    echo "Run install-fusion.sh first."
    exit 1
fi

# Pre-warm IDSDK. Wine's CreateProcess cold-start (~15s) races against
# Fusion's 15s SSO-readiness timeout; losing gives error 3213. Polling
# the IDM log lets a fast start not waste time. Opt out: FUSION_PREWARM_IDM=0.
if [ "${FUSION_PREWARM_IDM:-1}" = 1 ]; then
    IDM_EXE=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production" \
        -name AdskIdentityManager.exe -print -quit 2>/dev/null)
    if [ -n "$IDM_EXE" ]; then
        IDM_LOG="$PREFIX/drive_c/users/$USER/AppData/Local/Autodesk/Identity Services/Log/IdServices.log"
        : >"$IDM_LOG" 2>/dev/null || true

        echo "[$(date +%H:%M:%S)] pre-launching IDSDK..."
        PREWARM_T0=$(date +%s.%N)
        "$WINE_BIN" "$IDM_EXE" \
            --process_name Autodesk.IDSDK.DefaultProcess-v2 \
            --server_name Autodesk.IDSDK.DefaultServer-v2 \
            >/dev/null 2>&1 &

        # Marker matches the same "IPC listening" line Fusion's SDK waits on. Cap 45s.
        READY=0
        for i in $(seq 1 90); do
            if [ -s "$IDM_LOG" ] && grep -aq "Starting async call to listen for new connection" "$IDM_LOG" 2>/dev/null; then
                READY=1
                break
            fi
            sleep 0.5
        done

        PREWARM_T1=$(date +%s.%N)
        PREWARM_ELAPSED=$(awk "BEGIN{printf \"%.2f\", $PREWARM_T1 - $PREWARM_T0}")
        if [ "$READY" = 1 ]; then
            echo "[$(date +%H:%M:%S)] IDSDK ready in ${PREWARM_ELAPSED}s; launching Fusion..."
        else
            echo "[$(date +%H:%M:%S)] IDSDK readiness not observed after ${PREWARM_ELAPSED}s - launching anyway"
        fi
    fi
fi

# Qt text engine — Qt 6.8's DirectWrite default breaks under wine's dwrite;
# freetype is least-broken. gdi drops capital I ("Insert" → "nsert").
# Values: freetype (default) | gdi | directwrite (diagnostic).
FUSION_QT_TEXT_ENGINE="${FUSION_QT_TEXT_ENGINE:-freetype}"
case "$FUSION_QT_TEXT_ENGINE" in
    freetype)    QT_PLATFORM_ARG="windows:fontengine=freetype" ;;
    gdi)         QT_PLATFORM_ARG="windows:nodirectwrite" ;;
    directwrite) QT_PLATFORM_ARG="" ;;
    *)           echo "WARN: unknown FUSION_QT_TEXT_ENGINE=$FUSION_QT_TEXT_ENGINE, using default freetype"
                 QT_PLATFORM_ARG="windows:fontengine=freetype" ;;
esac

cd "$(dirname "$FUSION_EXE")"
if [ -n "$QT_PLATFORM_ARG" ]; then
    exec "$WINE_BIN" Fusion360.exe -platform "$QT_PLATFORM_ARG" "$@"
else
    exec "$WINE_BIN" Fusion360.exe "$@"
fi
