#!/bin/bash
# Build the minimal WebView2 host test app via winegcc.
#
# Output: webview2_host.exe (PE) + webview2_host.exe.so (wine wrapper).
# Run via run.sh (which sets up the wineprefix + trace capture).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

WINE_BIN_DIR="${WINE_BIN_DIR:-$HOME/wine-versions/wine-11.10-fusion/bin}"
WINEGCC="$WINE_BIN_DIR/winegcc"

if [ ! -x "$WINEGCC" ]; then
    echo "winegcc not found at $WINEGCC — set WINE_BIN_DIR" >&2
    exit 1
fi

echo "[build] using $WINEGCC"
# Build as console app (-mconsole, NOT -mwindows) so fprintf(stderr) is
# visible in the captured trace. WinMain still works (winegcc generates
# the entry-point stub for either mode).
"$WINEGCC" -m64 -mconsole -o webview2_host.exe webview2_host.c \
    -lole32 -loleaut32 -ladvapi32 -luuid -lshell32

echo "[build] OK — webview2_host.exe + webview2_host.exe.so created"
ls -la webview2_host.exe webview2_host.exe.so 2>/dev/null || true
