#!/bin/bash
# Fast incremental rebuild — edit cached source in place, make, copy .so/.dll
# into the install prefix. Requires prior build-wine.sh.

set -euo pipefail

WINE_VERSION="11.10"
INSTALL_PREFIX="${WINE_INSTALL_PREFIX:-$HOME/wine-versions/wine-${WINE_VERSION}-fusion}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box/wine-build"
SRC_DIR="$CACHE_DIR/wine-${WINE_VERSION}"
BUILD_DIR="$SRC_DIR/build"

log() { echo "[$(date +%H:%M:%S)] $*"; }

[ -d "$SRC_DIR" ] || { echo "no source tree at $SRC_DIR - run build-wine.sh first" >&2; exit 1; }
[ -d "$BUILD_DIR" ] || { echo "no build dir at $BUILD_DIR - run build-wine.sh first" >&2; exit 1; }

# WINE_WORK_TREE — sync edits from an out-of-tree working copy into $SRC_DIR.
if [ -n "${WINE_WORK_TREE:-}" ]; then
    log "syncing source edits from $WINE_WORK_TREE -> $SRC_DIR"
    rsync -a --include='*.c' --include='*.h' --include='*.xml' --include='*/' --exclude='*' \
        "$WINE_WORK_TREE/dlls/winewayland.drv/" "$SRC_DIR/dlls/winewayland.drv/"
fi

log "make -j$(nproc) in $BUILD_DIR"
( cd "$BUILD_DIR" && make -j"$(nproc)" 2>&1 | tail -20 )

log "copying rebuilt binaries to $INSTALL_PREFIX"
# Copy every freshly-built .so (Unix wine modules) and .dll (PE builtins).
# Filter by -newer stamp so we only touch what actually changed this build.
find "$BUILD_DIR/dlls" "$BUILD_DIR/programs" \( -name '*.so' -o -name '*.dll' \) \
    -newer "$INSTALL_PREFIX/.fusion-box-build-stamp" \
    -print 2>/dev/null | while read f; do

    rel="${f#$BUILD_DIR/}"
    base="$(basename "$f")"
    for target_dir in lib/wine/x86_64-unix lib/wine/x86_64-windows; do
        target="$INSTALL_PREFIX/$target_dir/$base"
        if [ -f "$target" ]; then
            cp -p "$f" "$target"
            echo "  $rel -> $target"
        fi
    done
done

log "fast rebuild done"
"$INSTALL_PREFIX/bin/wine" --version
