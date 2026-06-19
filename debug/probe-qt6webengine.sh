#!/bin/bash
# Reproducible probe of Fusion's bundled Qt6WebEngineCore.dll.
#
# Captures the static facts needed to investigate the Data Panel render bug:
# Qt+Chromium versions, file mtimes, source-path strings, single-process
# references, build-config strings, and the auto-update history that
# correlates with when the panel broke.
#
# Idempotent and read-only. Writes captures to debug/captures/qtwe-probe-<ts>.txt.
#
# Background: Data Panel renders blank under wine winewayland.drv because the
# Chromium subprocess (spawned by Qt6WebEngineCore) creates HWNDs in a different
# wine process than the Qt toplevel, so winewayland.drv can't find the parent
# wayland_surface to anchor a subsurface. The 2026-06-18 webdeploy audit found
# Fusion auto-updated Qt6WebEngineCore on 2026-06-12, breaking compatibility.
# See docs/qt6webengine-binary-patch.md for the investigation log.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$REPO_DIR/debug/captures/qtwe-probe-$TS.txt"

PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
WEBDEPLOY="$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"

mkdir -p "$(dirname "$OUT")"

# Find the currently-active Fusion install dir (Autodesk's webdeploy keeps the
# real install under a hash-named subdir; the launcher-only dir contains just
# .ico/.exe files).
INSTALL_DIR=$(find "$WEBDEPLOY" -maxdepth 1 -mindepth 1 -type d \
    -exec test -e {}/Qt6WebEngineCore.dll \; -print 2>/dev/null | head -1)

if [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: no Qt6WebEngineCore.dll under $WEBDEPLOY" >&2
    exit 1
fi

DLL="$INSTALL_DIR/Qt6WebEngineCore.dll"

{
    echo "=== Probe TS: $TS ==="
    echo "=== Install dir: $INSTALL_DIR ==="
    echo

    echo "=== Qt6WebEngineCore.dll info ==="
    ls -lh "$DLL"
    file "$DLL"
    echo

    echo "=== Qt version (from Qt6Core.dll) ==="
    strings -n 6 "$INSTALL_DIR/Qt6Core.dll" 2>/dev/null \
        | grep -E "^Qt [0-9]\.[0-9]\.[0-9]" | head -1
    echo "qVersion symbol in WebEngineCore:"
    strings -n 4 "$DLL" | grep -E "^6\.[0-9]+\.[0-9]+$" | head -3
    echo

    echo "=== Bundled Chromium version ==="
    strings -n 8 "$DLL" | grep -iE "Chrome/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
        | sort -u | head -3
    echo

    echo "=== Build config (path tells us toolchain/config) ==="
    strings -n 30 "$DLL" | grep -E "C:[/\\\\].*qtwebengine[/\\\\]src[/\\\\]" \
        | head -3
    echo

    echo "=== Source-path strings (helps locate functions in radare2) ==="
    strings -n 30 "$DLL" | grep -E "qtwebengine[/\\\\]src[/\\\\]core" \
        | sort -u | wc -l
    echo "(count of unique qtwebengine/src/core source paths embedded)"
    echo

    echo "=== Single-process related strings ==="
    strings -n 8 "$DLL" | grep -iE "single.process|single_process|kSingleProcess" \
        | sort -u
    echo

    echo "=== Multi-process / sandbox related strings ==="
    strings -n 12 "$DLL" | grep -iE "ProcessType|process.type|sandbox|QtWebEngineProcess|--type=" \
        | head -20
    echo

    echo "=== Webdeploy mtime audit (DLL update history) ==="
    echo "DLLs grouped by mtime (date count):"
    find "$INSTALL_DIR" -maxdepth 1 -name "*.dll" -printf "%TY-%Tm-%Td\n" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -10
    echo
    echo "All Qt*.dll updated after initial-install date (look for the panel-breaking update):"
    INITIAL_DATE=$(find "$INSTALL_DIR" -maxdepth 1 -name "*.dll" -printf "%TY-%Tm-%Td\n" 2>/dev/null \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    echo "  initial-install date (most-common mtime): $INITIAL_DATE"
    find "$INSTALL_DIR" -maxdepth 1 -name "Qt6*.dll" -newermt "$INITIAL_DATE" \
        -printf "  %TY-%Tm-%Td  %10s  %f\n" 2>/dev/null | sort
    echo

    echo "=== fusion-box's own Qt backup dir (from prior MinGW experiment, if any) ==="
    BACKUP="$INSTALL_DIR/.fusion-box-qt-backup"
    if [ -d "$BACKUP" ]; then
        find "$BACKUP" -type f -printf "  %TY-%Tm-%Td  %10s  %P\n" | sort
    else
        echo "  (no backup dir present)"
    fi
} > "$OUT"

echo "wrote $OUT"
echo "---"
cat "$OUT"
