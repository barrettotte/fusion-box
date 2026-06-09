#!/bin/bash
# Host-side URL handler for adskidmgr:// scheme.
# Re-enters fusion-box and invokes AdskIdentityManager.exe with the callback URL.
# Wired up by the .desktop file written by scripts/install-host-handler.sh.

set -euo pipefail

LOG=/tmp/fusion-debug/adskidmgr-handler.log
mkdir -p /tmp/fusion-debug

{
    echo "----"
    date '+%Y-%m-%d %H:%M:%S'
    echo "argv=$*"
    echo "url=${1:-<unset>}"
} >> "$LOG" 2>&1

URL="${1:-}"
[ -n "$URL" ] || { echo "usage: $0 adskidmgr://..." >&2; exit 1; }

{ echo "invoking IDM..."; } >> "$LOG" 2>&1
distrobox enter fusion-box -- bash -lc "
    export WINEPREFIX=\$HOME/.wine-fusion
    # Must use the same wine binary the launcher used so the wineserver versions match - otherwise this fires
    # up a SEPARATE wineserver and the new IDM process can't talk to the Fusion process already running under
    # the launcher's wineserver. Prefer the patched build if present; fall back to the system wine.
    PATCHED=\$HOME/wine-versions/wine-11.10-fusion/bin/wine
    if [ -x \"\$PATCHED\" ]; then WINE_BIN=\"\$PATCHED\"; else WINE_BIN=wine; fi
    IDM=\$(find \"\$WINEPREFIX/drive_c/Program Files/Autodesk/webdeploy/production\" \
        -name AdskIdentityManager.exe -print -quit 2>/dev/null)
    [ -n \"\$IDM\" ] || { echo 'AdskIdentityManager.exe not found' >&2; exit 1; }
    exec \"\$WINE_BIN\" \"\$IDM\" '$URL'
" >> "$LOG" 2>&1
echo "exit_code=$?" >> "$LOG"
