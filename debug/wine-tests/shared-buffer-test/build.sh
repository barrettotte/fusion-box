#!/bin/bash
# Build shared-buffer-test.c.
#
# Needs wayland-scanner + wayland-protocols installed. Inside fusion-box,
# `sudo pacman -S --needed wayland-protocols` (wayland is already pulled in by
# wine-staging). On other distros: wayland-protocols-devel / libwayland-dev.
#
# Generates xdg-shell-client-protocol.h/.c and viewporter-client-protocol.h/.c
# next to the .c file, then compiles to ./shared-buffer-test.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PROTO_DIR=${WAYLAND_PROTOCOLS_DIR:-/usr/share/wayland-protocols}
XDG_XML="$PROTO_DIR/stable/xdg-shell/xdg-shell.xml"
VP_XML="$PROTO_DIR/stable/viewporter/viewporter.xml"
DECO_XML="$PROTO_DIR/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
SCANNER=${WAYLAND_SCANNER:-wayland-scanner}

[ -f "$XDG_XML"  ] || { echo "missing $XDG_XML (install wayland-protocols)" >&2; exit 1; }
[ -f "$VP_XML"   ] || { echo "missing $VP_XML (install wayland-protocols)" >&2; exit 1; }
[ -f "$DECO_XML" ] || { echo "missing $DECO_XML (install wayland-protocols)" >&2; exit 1; }
command -v "$SCANNER" >/dev/null || { echo "$SCANNER not on PATH" >&2; exit 1; }

"$SCANNER" client-header "$XDG_XML"  xdg-shell-client-protocol.h
"$SCANNER" private-code  "$XDG_XML"  xdg-shell-client-protocol.c
"$SCANNER" client-header "$VP_XML"   viewporter-client-protocol.h
"$SCANNER" private-code  "$VP_XML"   viewporter-client-protocol.c
"$SCANNER" client-header "$DECO_XML" xdg-decoration-unstable-v1-client-protocol.h
"$SCANNER" private-code  "$DECO_XML" xdg-decoration-unstable-v1-client-protocol.c

gcc -O2 -Wall -Wextra -o shared-buffer-test \
    shared-buffer-test.c \
    xdg-shell-client-protocol.c \
    viewporter-client-protocol.c \
    xdg-decoration-unstable-v1-client-protocol.c \
    -lwayland-client -lrt

echo "built ./shared-buffer-test"
