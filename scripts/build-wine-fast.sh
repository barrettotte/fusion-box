#!/bin/bash
# Fast incremental rebuild of patched wine.
#
# Use this when you've made small source edits and want to retest quickly.
# Edits the cached extracted source in place, runs `make`, and copies the rebuilt .so files into the install prefix.
#
# Requires prior full build via scripts/build-wine.sh so source tree and build dir exist. Aborts if either is missing.

set -euo pipefail

WINE_VERSION="11.10"
INSTALL_PREFIX="${WINE_INSTALL_PREFIX:-$HOME/wine-versions/wine-${WINE_VERSION}-fusion}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box/wine-build"
SRC_DIR="$CACHE_DIR/wine-${WINE_VERSION}"
BUILD_DIR="$SRC_DIR/build"

log() { echo "[$(date +%H:%M:%S)] $*"; }

[ -d "$SRC_DIR" ] || { echo "no source tree at $SRC_DIR - run build-wine.sh first" >&2; exit 1; }
[ -d "$BUILD_DIR" ] || { echo "no build dir at $BUILD_DIR - run build-wine.sh first" >&2; exit 1; }

# Allow the caller to point at a different working tree they're iterating in. If WINE_WORK_TREE is set, sync the
# changed files from there into $SRC_DIR before building. Otherwise assume edits are in-place in $SRC_DIR.
if [ -n "${WINE_WORK_TREE:-}" ]; then
    log "syncing source edits from $WINE_WORK_TREE -> $SRC_DIR"
    # Sync the whole winewayland.drv tree so any file we touch
    # (including wayland_pointer.c, wayland_keyboard.c, new protocol XMLs, etc.)
    # gets picked up by make. Skip nothing.
    rsync -a --include='*.c' --include='*.h' --include='*.xml' --include='*/' --exclude='*' \
        "$WINE_WORK_TREE/dlls/winewayland.drv/" "$SRC_DIR/dlls/winewayland.drv/"
fi

log "make -j$(nproc) in $BUILD_DIR"
( cd "$BUILD_DIR" && make -j"$(nproc)" 2>&1 | tail -20 )

log "copying rebuilt binaries to $INSTALL_PREFIX"
# winewayland.so is the only file we typically iterate on. cp every freshly-built .so/.so.* under build/dlls
# and build/programs to keep things general.
find "$BUILD_DIR/dlls" "$BUILD_DIR/programs" -name '*.so' -newer "$INSTALL_PREFIX/.fusion-box-build-stamp" \
    -print 2>/dev/null | while read f; do

    rel="${f#$BUILD_DIR/}"
    # build paths look like build/dlls/winewayland.drv/winewayland.so
    # install paths are $INSTALL_PREFIX/lib/wine/x86_64-unix/winewayland.so
    base="$(basename "$f")"
    target="$INSTALL_PREFIX/lib/wine/x86_64-unix/$base"
    if [ -f "$target" ]; then
        cp -p "$f" "$target"
        echo "  $rel -> $target"
    fi
done

log "fast rebuild done"
"$INSTALL_PREFIX/bin/wine" --version
