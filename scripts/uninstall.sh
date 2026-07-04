#!/bin/bash
# Uninstall fusion-box from the host.
#
# Runs on the HOST. Removes (in order):
#   - host launcher (fusion-box.desktop) + extracted icons
#   - host adskidmgr:// handler
#   - distrobox container "fusion-box"
#   - podman image localhost/fusion-box:latest      (--keep-image to skip)
#   - patched wine install prefix
#   - Fusion wineprefix (LARGE — several GB)
#   - build + download caches (~/.cache/fusion-box) (--keep-cache to skip)
#
# Env vars honored (same as install-* scripts):
#   BOX_HOME=/path            location of container's $HOME (wineprefix + wine live here)
#   WINEPREFIX_FUSION=/path   explicit override
#   WINE_INSTALL_PREFIX=/path explicit override
#   CONTAINER_NAME=fusion-box override container name
#
# Flags:
#   --yes         non-interactive; skip the confirmation prompt
#   --dry-run     print what would be removed and exit
#   --keep-image  don't remove the podman image
#   --keep-cache  don't remove ~/.cache/fusion-box

set -euo pipefail

YES=0
DRY_RUN=0
KEEP_IMAGE=0
KEEP_CACHE=0
for arg in "$@"; do
    case "$arg" in
        --yes)        YES=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --keep-image) KEEP_IMAGE=1 ;;
        --keep-cache) KEEP_CACHE=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

CONTAINER_NAME="${CONTAINER_NAME:-fusion-box}"
IMAGE="localhost/fusion-box:latest"

# Where wineprefix + wine install live: BOX_HOME wins over $HOME. Explicit vars win over both.
BASE_HOME="${BOX_HOME:-$HOME}"
PREFIX="${WINEPREFIX_FUSION:-$BASE_HOME/.wine-fusion}"
WINE_PREFIX_INSTALL="${WINE_INSTALL_PREFIX:-$BASE_HOME/wine-versions/wine-11.10-fusion}"
CACHE_DIRS=(
    "${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box"
    "$BASE_HOME/.cache/fusion-box"
)

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
LAUNCHER="$DATA_HOME/applications/fusion-box.desktop"
HANDLER="$DATA_HOME/applications/adskidmgr-fusion-box.desktop"
ICON_GLOB="$DATA_HOME/icons/hicolor/*/apps/fusion-box.png"
ICON_RAW="$DATA_HOME/icons/fusion-box.ico"

# ---- inventory pass ----
plan=()
add() { plan+=("$1"); }

[ -f "$LAUNCHER" ] && add "rm  $LAUNCHER"
[ -f "$HANDLER" ]  && add "rm  $HANDLER"
[ -f "$ICON_RAW" ] && add "rm  $ICON_RAW"
compgen -G "$ICON_GLOB" > /dev/null 2>&1 && add "rm  $ICON_GLOB (extracted icon sizes)"

if command -v distrobox >/dev/null && \
   distrobox list 2>/dev/null | awk '{print $3}' | grep -qx "$CONTAINER_NAME"; then
    add "distrobox rm -f $CONTAINER_NAME"
fi

if [ "$KEEP_IMAGE" = 0 ] && command -v podman >/dev/null && \
   podman image exists "$IMAGE" 2>/dev/null; then
    add "podman rmi $IMAGE"
fi

[ -d "$WINE_PREFIX_INSTALL" ] && add "rm -rf $WINE_PREFIX_INSTALL (patched wine install)"

if [ -d "$PREFIX" ]; then
    size=$(du -sh "$PREFIX" 2>/dev/null | cut -f1)
    add "rm -rf $PREFIX (Fusion wineprefix, ~${size:-unknown})"
fi

if [ "$KEEP_CACHE" = 0 ]; then
    for c in "${CACHE_DIRS[@]}"; do
        [ -d "$c" ] && add "rm -rf $c (build + download cache)"
    done
fi

if [ ${#plan[@]} -eq 0 ]; then
    echo "Nothing to remove — fusion-box already uninstalled."
    exit 0
fi

echo "Will remove:"
for step in "${plan[@]}"; do echo "  $step"; done

if [ "$DRY_RUN" = 1 ]; then
    echo
    echo "(dry run — nothing removed)"
    exit 0
fi

if [ "$YES" = 0 ]; then
    echo
    read -rp "Proceed? [y/N] " ans
    case "$ans" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

# ---- actual removal ----
[ -f "$LAUNCHER" ] && rm -f "$LAUNCHER" && echo "removed $LAUNCHER"
[ -f "$HANDLER" ]  && rm -f "$HANDLER"  && echo "removed $HANDLER"
[ -f "$ICON_RAW" ] && rm -f "$ICON_RAW" && echo "removed $ICON_RAW"

for f in $ICON_GLOB; do
    [ -f "$f" ] && rm -f "$f" && echo "removed $f"
done

if command -v distrobox >/dev/null && \
   distrobox list 2>/dev/null | awk '{print $3}' | grep -qx "$CONTAINER_NAME"; then
    distrobox rm -f "$CONTAINER_NAME"
fi

if [ "$KEEP_IMAGE" = 0 ] && command -v podman >/dev/null && \
   podman image exists "$IMAGE" 2>/dev/null; then
    podman rmi "$IMAGE"
fi

[ -d "$WINE_PREFIX_INSTALL" ] && rm -rf "$WINE_PREFIX_INSTALL" && echo "removed $WINE_PREFIX_INSTALL"
[ -d "$PREFIX" ]              && rm -rf "$PREFIX"              && echo "removed $PREFIX"

if [ "$KEEP_CACHE" = 0 ]; then
    for c in "${CACHE_DIRS[@]}"; do
        [ -d "$c" ] && rm -rf "$c" && echo "removed $c"
    done
fi

if command -v update-desktop-database >/dev/null; then
    update-desktop-database "$DATA_HOME/applications" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" 2>/dev/null || true
fi
if command -v kbuildsycoca6 >/dev/null; then
    kbuildsycoca6 >/dev/null 2>&1 || true
fi

echo
echo "fusion-box uninstalled."
