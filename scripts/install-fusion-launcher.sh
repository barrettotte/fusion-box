#!/bin/bash
# Install a host desktop launcher for Fusion 360 (in fusion-box distrobox).
#
# Runs on the HOST (not inside the container). Creates:
#   ~/.local/share/icons/hicolor/{16,24,32,48,64,96,128,256}x{...}/apps/fusion-box.png
#   ~/.local/share/applications/fusion-box.desktop   (launcher → distrobox enter + launch-fusion.sh)
#
# WINEPREFIX_FUSION=/path/to/.wine-fusion  override prefix location (needed when BOX_HOME was set)
# CONTAINER_NAME=fusion-box                override distrobox container name
#
# Requires ImageMagick (`magick`) or icoutils (`icotool`) on host to extract multi-res PNGs from
# Fusion360.ico; falls back to a single blurry .ico copy if neither is present.
#
# Idempotent — re-run to refresh paths/icons after moving the repo or updating Fusion.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH_SCRIPT="$REPO_DIR/scripts/launch-fusion.sh"
PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
CONTAINER_NAME="${CONTAINER_NAME:-fusion-box}"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
ICON_ROOT="$DATA_HOME/icons/hicolor"
APP_DIR="$DATA_HOME/applications"
DESKTOP="$APP_DIR/fusion-box.desktop"

[ -x "$LAUNCH_SCRIPT" ] || { echo "launch script missing: $LAUNCH_SCRIPT" >&2; exit 1; }
[ -d "$PREFIX" ]        || { echo "wineprefix not found at $PREFIX (set WINEPREFIX_FUSION)" >&2; exit 1; }
command -v distrobox               >/dev/null || { echo "distrobox not on PATH" >&2; exit 1; }
command -v update-desktop-database >/dev/null || { echo "update-desktop-database missing (install desktop-file-utils)" >&2; exit 1; }

SRC_ICON=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy" -maxdepth 3 -name Fusion360.ico -print -quit 2>/dev/null)
[ -n "$SRC_ICON" ] || { echo "Fusion360.ico not found under $PREFIX/... — is Fusion installed?" >&2; exit 1; }

install_icon() {
    # Try magick first (handles PNG-encoded frames + malformed BMP entries).
    if command -v magick >/dev/null; then
        # `identify` lists one line per embedded frame; extract each into its own hicolor dir.
        magick identify -format '%w %h %s\n' "$SRC_ICON" | while read -r w h scene; do
            [ "$w" = "$h" ] || continue
            case "$w" in 16|24|32|48|64|96|128|256) ;; *) continue ;; esac
            dest="$ICON_ROOT/${w}x${h}/apps/fusion-box.png"
            mkdir -p "$(dirname "$dest")"
            magick "${SRC_ICON}[$scene]" "$dest"
            echo "  extracted ${w}x${h} → $dest"
        done
        return 0
    fi

    # Fallback: icotool (icoutils) — extracts every embedded PNG at once.
    if command -v icotool >/dev/null; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' RETURN
        if icotool -x -o "$tmp" "$SRC_ICON" 2>/dev/null; then
            for f in "$tmp"/*.png; do
                [ -f "$f" ] || continue
                sz=$(basename "$f" | sed -E 's/.*_([0-9]+)x[0-9]+x[0-9]+\.png$/\1/')
                case "$sz" in 16|24|32|48|64|96|128|256) ;; *) continue ;; esac
                dest="$ICON_ROOT/${sz}x${sz}/apps/fusion-box.png"
                mkdir -p "$(dirname "$dest")"
                cp "$f" "$dest"
                echo "  extracted ${sz}x${sz} → $dest"
            done
            return 0
        fi
    fi

    # Last-resort: raw .ico copy (KDE picks the smallest frame → blurry).
    dest="$DATA_HOME/icons/fusion-box.ico"
    cp -f "$SRC_ICON" "$dest"
    echo "  WARNING: no magick/icotool available — copied raw .ico to $dest"
    echo "  Install ImageMagick or icoutils on host and re-run for crisp icons."
    ICON_NAME_OVERRIDE="$dest"
}

echo "Extracting icon from $SRC_ICON"
install_icon

mkdir -p "$APP_DIR"

# Icon= just the theme name (`fusion-box`) triggers hicolor size lookup per context.
# If we fell back to raw .ico, use its absolute path instead.
ICON_LINE="Icon=${ICON_NAME_OVERRIDE:-fusion-box}"

cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Autodesk Fusion (fusion-box)
Comment=Autodesk Fusion 360 under patched wine in the fusion-box distrobox
Exec=distrobox enter $CONTAINER_NAME -- bash $LAUNCH_SCRIPT
$ICON_LINE
Categories=Graphics;3DGraphics;Engineering;
Terminal=false
StartupNotify=true
EOF

update-desktop-database "$APP_DIR"

# Refresh the hicolor icon cache so KDE/GNOME pick up new sizes without a session restart.
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true
fi
if command -v kbuildsycoca6 >/dev/null; then
    kbuildsycoca6 >/dev/null 2>&1 || true
fi

echo
echo "Installed launcher: $DESKTOP"
echo "Exec:               distrobox enter $CONTAINER_NAME -- bash $LAUNCH_SCRIPT"
