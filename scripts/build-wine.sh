#!/bin/bash
# Build a patched wine for fusion-box.
#
# Why: wine 11.10's winewayland.drv does not bind zxdg_decoration_manager_v1, so on KDE Plasma 6
# the compositor unilaterally draws SSD borders that wine doesn't know about.
# The result is title-bar drag broken and pointer events in the would-be-content area getting
# captured by KWin as resize-start.
# Patching wine to speak the decoration protocol (MR !10259) fixes both.
#
# Idempotent: re-runs cheap if the install dir already exists and its patch stamp matches the current patches/wine/ contents.
# Force a rebuild with `BUILD_WINE_FORCE=1`.

set -euo pipefail

WINE_VERSION="11.10"
WINE_SRC_URL="https://dl.winehq.org/wine/source/11.x/wine-${WINE_VERSION}.tar.xz"
INSTALL_PREFIX="${WINE_INSTALL_PREFIX:-$HOME/wine-versions/wine-${WINE_VERSION}-fusion}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/patches/wine"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box/wine-build"
SRC_TARBALL="$CACHE_DIR/wine-${WINE_VERSION}.tar.xz"
SRC_DIR="$CACHE_DIR/wine-${WINE_VERSION}"
BUILD_DIR="$SRC_DIR/build"
STAMP_FILE="$INSTALL_PREFIX/.fusion-box-build-stamp"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Honour MAX_PATCH_NUM if set: emit only patches whose numeric prefix is <= the limit.
# Used to bisect which patch introduces a regression — `MAX_PATCH_NUM=0` builds vanilla,
# `MAX_PATCH_NUM=6` builds with patches 0001..0006.
filtered_patches() {
    for p in "$PATCHES_DIR"/*.patch; do
        [ -f "$p" ] || continue
        if [ -n "${MAX_PATCH_NUM:-}" ]; then
            num=$(basename "$p" | sed -E 's/^0*([0-9]+).*/\1/')
            [ "$num" -le "$MAX_PATCH_NUM" ] || continue
        fi
        echo "$p"
    done
}

# Compute a stamp of (wine version + sha256 of applied patches in order). Lets us skip rebuilds when nothing has changed.
expected_stamp() {
    {
        echo "wine=${WINE_VERSION}"
        filtered_patches | while read -r p; do
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

if [ -n "${MAX_PATCH_NUM:-}" ]; then
    log "applying patches from $PATCHES_DIR (MAX_PATCH_NUM=$MAX_PATCH_NUM)"
else
    log "applying patches from $PATCHES_DIR"
fi
filtered_patches | while read -r p; do
    log "  $(basename "$p")"
    ( cd "$SRC_DIR" && patch -p1 < "$p" >/dev/null )
done

mkdir -p "$BUILD_DIR"

# Wrap host + cross compilers with ccache when available. Wine has separate
# CC vars per arch; matching the wrapping cuts incremental rebuild times
# from ~5 minutes to ~30 seconds on a warm cache (most files unchanged
# between patches/wine/* iterations). Cache lives in ~/.ccache (host-mounted
# home, so persists across container restarts). Opt out with USE_CCACHE=0.
CCACHE_ARGS=()
if [ "${USE_CCACHE:-1}" = 1 ] && command -v ccache >/dev/null; then
    CCACHE_ARGS=(
        CC="ccache gcc"
        x86_64_CC="ccache x86_64-w64-mingw32-gcc"
    )
    log "ccache wrapping enabled ($(ccache --version | head -1))"
fi

log "configure"
( cd "$BUILD_DIR" && ../configure --prefix="$INSTALL_PREFIX" \
    --enable-archs=x86_64 --disable-tests \
    "${CCACHE_ARGS[@]}" > configure.log 2>&1 )

log "build (this takes a few minutes)"
( cd "$BUILD_DIR" && make -j"$(nproc)" > build.log 2>&1 )

log "install to $INSTALL_PREFIX"
rm -rf "$INSTALL_PREFIX"
( cd "$BUILD_DIR" && make install > install.log 2>&1 )

echo "$EXPECTED" > "$STAMP_FILE"
log "done"
"$INSTALL_PREFIX/bin/wine" --version
