#!/bin/bash
# Launch Autodesk Fusion 360 from the fusion-box wineprefix.

set -euo pipefail

PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:-fixme-all,err-winediag}"

# Kill any prior wine session before launching to avoid Fusion's "Multiple instances are not supported" dialog and
# clear orphaned msedgewebview2 / IDM / cer_dialog / wineserver processes.
# wineserver -k brings down the current session, but Autodesk's CER dialog and stray WebView2 children sometimes
# survive in a detached process tree - pkill by exe name catches those.
pkill -9 -f cer_dialog 2>/dev/null || true
pkill -9 -f msedgewebview2 2>/dev/null || true
pkill -9 -f Fusion360.exe 2>/dev/null || true
pkill -9 -f AdskIdentityManager.exe 2>/dev/null || true

# Now bring down every wineserver we might have used (container system wine, GE-Proton variants,
# side-by-side builds under ~/wine-versions/).
wineserver -k 2>/dev/null || true
for ws in "$HOME"/wine-versions/*/bin/wineserver "$HOME"/wine-versions/*/usr/bin/wineserver; do
    [ -x "$ws" ] && "$ws" -k 2>/dev/null || true
done
sleep 2

# WINEDLLOVERRIDES:
#   bcp47langs=        - IDM (AdskIdentityManager.exe) calls the unimplemented bcp47langs.dll!GetUserLanguages export.
#                        Without this override, wine aborts the entire process before IDM can finish init. cf.
#                        wine MR !6131, cryinkfly issue #432.
#   winewayland.drv=b  - Use wine's native Wayland driver instead of winex11.drv.
#     winex11.drv=       Without this, wine paints through winex11 -> XWayland and the Qt6 sign-in dialog
#                        (and any subsequent Qt-rendered window) shows up as a uniform-black rectangle.
#                        Diagnosed 2026-06-06; confirmed on wine-staging 10.11 AND GE-Proton 10-34.
#                        Native winewayland.drv renders correctly. Set FUSION_FORCE_X11=1 to fall back to X11.
DRIVER_OVERRIDE='winewayland.drv=b;winex11.drv='
if [ "${FUSION_FORCE_X11:-0}" = 1 ]; then
    # Diagnostic-only escape hatch: force winex11.drv (XWayland). Tested 2026-06-07 - confirms most UI bugs
    # are wayland-specific (X11 path has working dock/toolbar/popups but the viewport goes black under DXVK).
    # NOT the goal - fusion-box's mission is to pioneer the wayland+vulkan path. Use only when isolating whether a bug is wayland-side.
    DRIVER_OVERRIDE='winewayland.drv=;winex11.drv=b'
fi
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}${DRIVER_OVERRIDE:+$DRIVER_OVERRIDE;}bcp47langs="

# Wine binary. Preference order:
#   1. $WINE_BIN if set
#   2. The patched build from scripts/build-wine.sh (adds winewayland SSD support;
#      see patches/wine/0001-winewayland-server-side-decorations.patch)
#   3. Container's system wine-staging
PATCHED_WINE="$HOME/wine-versions/wine-11.10-fusion/bin/wine"
if [ -n "${WINE_BIN:-}" ]; then
    :
elif [ -x "$PATCHED_WINE" ]; then
    WINE_BIN="$PATCHED_WINE"
else
    WINE_BIN="wine"
fi

# winebrowser.exe (used by any wine ShellExecute("https://...")) checks $BROWSER first, then a hard-coded list
# of /usr/bin/<browser> paths. None exist in this image, so without BROWSER set, AdskIdentityManager's OAuth
# redirect silently does nothing. Point at our xdg-open shim -> distrobox-host-exec -> host browser.
export BROWSER=/usr/local/bin/xdg-open

# Force Qt6 to scale 1:1 with physical pixels. Wine's wayland multi-monitor DPI handling confuses Qt's hover-driven
# cursor-shape updates if Qt is left to auto-scale per screen - the cursor visually stays as whatever it was on
# enter and never changes when hovering different widgets. Disabling Qt's HiDPI scaling pins everything to 1.0 and
# the cursor shape updates as expected. Fusion's UI on a 4K-class monitor will be small but legible.
export QT_ENABLE_HIGHDPI_SCALING=0
export QT_AUTO_SCREEN_SCALE_FACTOR=0
export QT_SCALE_FACTOR=1

# Most-recent Fusion360.exe under webdeploy/production.
# Fusion auto-update lands new versions as sibling hash dirs; this picks whichever was modified last.
FUSION_EXE=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production" \
    -name Fusion360.exe -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$FUSION_EXE" ]; then
    echo "ERROR: Fusion360.exe not found under $PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"
    echo "Run install-fusion.sh first."
    exit 1
fi

# Pre-warm the IDSDK backend before Fusion. Wine's CreateProcess for the IDM binary takes ~15s cold-start;
# Fusion has a hard-coded 15s timeout waiting for the SSO process to be "ready" - when wine loses the race,
# sign-in fails with error 3213 ("Process not ready") and the user sees an "Unable to sign in" dialog blaming firewall/antivirus.
#
# We pre-launch IDM and poll its log file for the IPC-listening line, which is the same readiness signal Fusion's SDK probes for.
# Polling instead of a fixed sleep means a fast cold-start doesn't waste seconds, and a slow one still completes before Fusion starts.
#
# Set FUSION_PREWARM_IDM=0 to opt out.
if [ "${FUSION_PREWARM_IDM:-1}" = 1 ]; then
    IDM_EXE=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production" \
        -name AdskIdentityManager.exe -print -quit 2>/dev/null)
    if [ -n "$IDM_EXE" ]; then
        # Truncate the IDM log so our marker grep below sees only this session.
        IDM_LOG="$PREFIX/drive_c/users/$USER/AppData/Local/Autodesk/Identity Services/Log/IdServices.log"
        : >"$IDM_LOG" 2>/dev/null || true

        echo "[$(date +%H:%M:%S)] pre-launching IDSDK..."
        PREWARM_T0=$(date +%s.%N)
        "$WINE_BIN" "$IDM_EXE" \
            --process_name Autodesk.IDSDK.DefaultProcess-v2 \
            --server_name Autodesk.IDSDK.DefaultServer-v2 \
            >/dev/null 2>&1 &

        # Poll the IDM log for the IPC-server-ready marker.
        # The line "Server:Autodesk.IDSDK.DefaultServer-v2:<pid>:<port>: Starting async call to listen for new connection"
        # appears exactly when Fusion's SDK would succeed at connecting. Cap at 45s as a safety ceiling.
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

cd "$(dirname "$FUSION_EXE")"
exec "$WINE_BIN" Fusion360.exe "$@"
