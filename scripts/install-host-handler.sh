#!/bin/bash
# Register the adskidmgr:// URL scheme handler on the HOST.
#
# Runs on the host (NOT inside distrobox), since the host browser is what follows the OAuth redirect
# into adskidmgr://. Writes a .desktop pointing at scripts/adskidmgr-handler.sh in this clone
# to ~/.local/share/applications/ and registers it as the default handler for x-scheme-handler/adskidmgr.
#
# Idempotent: re-running just rewrites + re-registers.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLER="$REPO_DIR/scripts/adskidmgr-handler.sh"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DEST="$DEST_DIR/adskidmgr-fusion-box.desktop"

[ -x "$HANDLER" ] || { echo "handler script missing or not executable: $HANDLER" >&2; exit 1; }
command -v xdg-mime                >/dev/null || {
    echo "xdg-mime not on PATH (install xdg-utils)" >&2; exit 1;
}
command -v update-desktop-database >/dev/null || {
    echo "update-desktop-database not on PATH (install desktop-file-utils)" >&2; exit 1;
}

mkdir -p "$DEST_DIR"

# xdg requires an absolute path in Exec= - ~ and $HOME are NOT expanded.
cat > "$DEST" <<EOF
[Desktop Entry]
Type=Application
Name=Autodesk Identity Manager (fusion-box)
Comment=Handles adskidmgr:// OAuth callbacks for Fusion 360 in fusion-box
Exec=$HANDLER %u
StartupNotify=false
NoDisplay=true
MimeType=x-scheme-handler/adskidmgr;
EOF

xdg-mime default adskidmgr-fusion-box.desktop x-scheme-handler/adskidmgr
update-desktop-database "$DEST_DIR"

echo "Registered $DEST"
echo "Default for x-scheme-handler/adskidmgr: $(xdg-mime query default x-scheme-handler/adskidmgr)"
