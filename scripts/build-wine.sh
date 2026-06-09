#!/bin/bash
# Build a patched wine for fusion-box.
#
# Why: wine 11.10's winewayland.drv does not bind zxdg_decoration_manager_v1, so on KDE Plasma 6
# the compositor unilaterally draws SSD borders that wine doesn't know about.
# The result is title-bar drag broken and pointer events in the would-be-content area getting
# captured by KWin as resize-start.
# Patching wine to speak the decoration protocol (MR !10259) fixes both.
#
# Idempotent: re-runs cheap if the install dir already exists and its patch stamp matches the current wine-patches/ contents.
# Force a rebuild with `BUILD_WINE_FORCE=1`.

set -euo pipefail

WINE_VERSION="11.10"
WINE_SRC_URL="https://dl.winehq.org/wine/source/11.x/wine-${WINE_VERSION}.tar.xz"
INSTALL_PREFIX="${WINE_INSTALL_PREFIX:-$HOME/wine-versions/wine-${WINE_VERSION}-fusion}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/wine-patches"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box/wine-build"
SRC_TARBALL="$CACHE_DIR/wine-${WINE_VERSION}.tar.xz"
SRC_DIR="$CACHE_DIR/wine-${WINE_VERSION}"
BUILD_DIR="$SRC_DIR/build"
STAMP_FILE="$INSTALL_PREFIX/.fusion-box-build-stamp"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Compute a stamp of (wine version + sha256 of all patches in order). Lets us skip rebuilds when nothing has changed.
expected_stamp() {
    {
        echo "wine=${WINE_VERSION}"
        for p in "$PATCHES_DIR"/*.patch; do
            [ -f "$p" ] || continue
            echo "patch=$(basename "$p"):$(sha256sum "$p" | cut -d' ' -f1)"
        done
    } | sha256sum | cut -d' ' -f1
}

EXPECTED=$(expected_stamp)

if [ "${BUILD_WINE_FORCE:-0}" != 1 ] && \
   [ -x "$INSTALL_PREFIX/bin/wine" ] && \
   [ -f "$STAMP_FILE" ] && \
   [ "$(cat "$STAMP_FILE")" = "$EXPECTED" ]; then
    log "already built (stamp matches at $STAMP_FILE)"
    "$INSTALL_PREFIX/bin/wine" --version
    exit 0
fi

mkdir -p "$CACHE_DIR"

if [ ! -f "$SRC_TARBALL" ]; then
    log "fetching wine ${WINE_VERSION} source"
    curl -fSL -o "$SRC_TARBALL.tmp" "$WINE_SRC_URL"
    mv "$SRC_TARBALL.tmp" "$SRC_TARBALL"
fi

rm -rf "$SRC_DIR"
log "extracting source"
tar -xf "$SRC_TARBALL" -C "$CACHE_DIR"

log "applying patches from $PATCHES_DIR"
for p in "$PATCHES_DIR"/*.patch; do
    [ -f "$p" ] || continue
    log "  $(basename "$p")"
    ( cd "$SRC_DIR" && patch -p1 < "$p" >/dev/null )
done

mkdir -p "$BUILD_DIR"
log "configure"
( cd "$BUILD_DIR" && ../configure --prefix="$INSTALL_PREFIX" --enable-archs=x86_64 --disable-tests > configure.log 2>&1 )

log "build (this takes a few minutes)"
( cd "$BUILD_DIR" && make -j"$(nproc)" > build.log 2>&1 )

log "install to $INSTALL_PREFIX"
rm -rf "$INSTALL_PREFIX"
( cd "$BUILD_DIR" && make install > install.log 2>&1 )

echo "$EXPECTED" > "$STAMP_FILE"
log "done"
"$INSTALL_PREFIX/bin/wine" --version
