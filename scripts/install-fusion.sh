#!/bin/bash
# Install Autodesk Fusion 360 inside the fusion-box wineprefix.
# Idempotent: re-running advances past completed phases.

set -euo pipefail

PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
CACHE="$HOME/.cache/fusion-box"
LOG="$CACHE/install.log"

# WebView2 evergreen bootstrapper (~2MB, pulls runtime on first run).
WEBVIEW2_URL="https://go.microsoft.com/fwlink/p/?LinkId=2124703"
# Fusion 360 Client Downloader (~13MB). The old "Admin Install.exe" URL is 403.
FUSION_URL="https://dl.appstreaming.autodesk.com/production/installers/Fusion%20Client%20Downloader.exe"

mkdir -p "$CACHE"
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "FAIL: $*"; exit 1; }

command -v wine       >/dev/null || die "wine not on PATH. Run this inside fusion-box: distrobox enter fusion-box"
command -v winetricks >/dev/null || die "winetricks not on PATH"
command -v curl       >/dev/null || die "curl not on PATH"

export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:-fixme-all,err-winediag}"

phase_wineboot() {
    if [ -d "$PREFIX/drive_c/windows/system32" ]; then
        log "wineprefix already initialized at $PREFIX"
        return
    fi
    log "wineboot -i (initializing $PREFIX)..."
    wineboot -i
}

phase_winetricks() {
    local marker="$PREFIX/.fusion-box-winetricks-done"
    if [ -f "$marker" ]; then
        log "winetricks verbs already applied"
        return
    fi
    log "installing winetricks verbs (corefonts, vcrun2022, dotnet48, d3dcompiler_47, mfc42, riched20, vkd3d, dxvk)..."
    winetricks --unattended \
        corefonts \
        vcrun2022 \
        dotnet48 \
        d3dcompiler_47 \
        mfc42 \
        riched20 \
        vkd3d \
        dxvk
    touch "$marker"
}

phase_winver() {
    local marker="$PREFIX/.fusion-box-winver-done"
    if [ -f "$marker" ]; then
        log "prefix Windows version already set"
        return
    fi
    # Fusion streamer rejects <Win10 build 1809.
    log "setting prefix Windows version to win11..."
    winetricks --unattended win11
    touch "$marker"
}

phase_webview2() {
    local marker="$PREFIX/.fusion-box-webview2-done"
    if [ -f "$marker" ]; then
        log "WebView2 already installed"
        return
    fi
    local installer="$CACHE/MicrosoftEdgeWebview2Setup.exe"
    if [ ! -f "$installer" ]; then
        log "downloading WebView2 bootstrapper..."
        curl -fL --retry 3 "$WEBVIEW2_URL" -o "$installer"
    fi
    log "running WebView2 bootstrapper (silent)..."
    wine "$installer" /silent /install
    touch "$marker"
}

phase_fusion() {
    if find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy" -name Fusion360.exe -print -quit 2>/dev/null | grep -q .; then
        log "Fusion360.exe already present"
        return
    fi
    local installer="$CACHE/FusionClientDownloader.exe"
    if [ ! -f "$installer" ]; then
        log "downloading Fusion 360 admin streamer..."
        curl -fL --retry 3 "$FUSION_URL" -o "$installer"
    fi
    # --quiet alone is a no-op; needs --globalinstall too (per Autodesk deployment guide).
    log "running Fusion streamer (downloads ~1 GB; expect 10-30 min over a slow link)..."
    wine "$installer" --globalinstall --quiet
}

verify() {
    local exe
    exe=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy" -name Fusion360.exe 2>/dev/null | head -1)
    [ -n "$exe" ] || die "Fusion360.exe not found after install. Check $LOG."
    log "OK: $exe"
}

log "===== install-fusion.sh start (prefix=$PREFIX) ====="
phase_wineboot
phase_winetricks
phase_winver
phase_webview2
phase_fusion
verify
log "===== install-fusion.sh done ====="
