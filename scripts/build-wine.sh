#!/bin/bash
# Build patched wine for fusion-box (mainline 11.10 + patches/wine/*).
#
# Usage:
#   ./build-wine.sh              # full build: fetch, patch, configure, make, install
#   ./build-wine.sh --fast       # incremental: make in cached tree + copy changed .so/.dll
#
# Env vars (full build):
#   USE_STAGING=1        wine-staging patchset before ours (default 0).
#   APPLY_FUSION_PATCHES=0  skip patches/wine/*.
#   BUILD_WINE_FORCE=1   force rebuild even if stamp matches.
#   USE_CCACHE=0         disable ccache wrapping.
#   MAX_PATCH_NUM=N      apply only patches 0001..000N (bisect).
#
# Env vars (--fast):
#   WINE_WORK_TREE=...   rsync winewayland.drv/ from this tree before rebuilding.
#
# Full build is idempotent — sha256-stamps wine version + patch list, skips if unchanged.

set -euo pipefail

FAST=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

WINE_VERSION="11.10"
WINE_SRC_URL="https://dl.winehq.org/wine/source/11.x/wine-${WINE_VERSION}.tar.xz"

USE_STAGING="${USE_STAGING:-0}"
WINE_STAGING_TAG="v${WINE_VERSION}"
WINE_STAGING_REPO="https://gitlab.winehq.org/wine/wine-staging.git"

APPLY_FUSION_PATCHES="${APPLY_FUSION_PATCHES:-1}"

INSTALL_PREFIX="${WINE_INSTALL_PREFIX:-$HOME/wine-versions/wine-${WINE_VERSION}-fusion}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/patches/wine"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box/wine-build"
SRC_TARBALL="$CACHE_DIR/wine-${WINE_VERSION}.tar.xz"
SRC_DIR="$CACHE_DIR/wine-${WINE_VERSION}"
STAGING_DIR="$CACHE_DIR/wine-staging-${WINE_VERSION}"
BUILD_DIR="$SRC_DIR/build"
STAMP_FILE="$INSTALL_PREFIX/.fusion-box-build-stamp"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- --fast path: incremental rebuild of cached source tree ---
if [ "$FAST" = 1 ]; then
    [ -d "$SRC_DIR" ]   || { echo "no source tree at $SRC_DIR - run without --fast first" >&2; exit 1; }
    [ -d "$BUILD_DIR" ] || { echo "no build dir at $BUILD_DIR - run without --fast first" >&2; exit 1; }

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
        -newer "$STAMP_FILE" \
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
    exit 0
fi

# --- full build path ---

# Emit patches whose numeric prefix is <= MAX_PATCH_NUM (bisect helper).
filtered_patches() {
    [ "$APPLY_FUSION_PATCHES" = 1 ] || return 0
    for p in "$PATCHES_DIR"/*.patch; do
        [ -f "$p" ] || continue
        if [ -n "${MAX_PATCH_NUM:-}" ]; then
            num=$(basename "$p" | sed -E 's/^0*([0-9]+).*/\1/')
            [ "$num" -le "$MAX_PATCH_NUM" ] || continue
        fi
        echo "$p"
    done
}

expected_stamp() {
    {
        echo "wine=${WINE_VERSION}"
        echo "staging=${USE_STAGING}"
        if [ "$USE_STAGING" = 1 ]; then
            echo "staging_tag=${WINE_STAGING_TAG}"
        fi
        echo "apply_fusion_patches=${APPLY_FUSION_PATCHES}"
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

# Fetch wine mainline source
if [ ! -f "$SRC_TARBALL" ]; then
    log "fetching wine ${WINE_VERSION} source"
    curl -fSL -o "$SRC_TARBALL.tmp" "$WINE_SRC_URL"
    mv "$SRC_TARBALL.tmp" "$SRC_TARBALL"
fi

rm -rf "$SRC_DIR"
log "extracting wine source"
tar -xf "$SRC_TARBALL" -C "$CACHE_DIR"

if [ "$USE_STAGING" = 1 ]; then
    if [ ! -d "$STAGING_DIR/.git" ]; then
        log "cloning wine-staging at ${WINE_STAGING_TAG}"
        rm -rf "$STAGING_DIR"
        git clone --depth 1 --branch "${WINE_STAGING_TAG}" \
            "$WINE_STAGING_REPO" "$STAGING_DIR"
    else
        log "wine-staging already cloned at $STAGING_DIR"
        # Verify pinned tag (will detach if user wants to change versions).
        ( cd "$STAGING_DIR" && git fetch --depth 1 origin "${WINE_STAGING_TAG}" 2>/dev/null || true )
        ( cd "$STAGING_DIR" && git checkout "${WINE_STAGING_TAG}" 2>&1 | tail -2 )
    fi

    log "applying wine-staging patchset (--all) via patchinstall.py"
    python3 "$STAGING_DIR/staging/patchinstall.py" --all DESTDIR="$SRC_DIR" \
        --backend=patch > "$CACHE_DIR/staging-patchinstall.log" 2>&1
    log "wine-staging patchset applied (log: $CACHE_DIR/staging-patchinstall.log)"
fi

if [ "$APPLY_FUSION_PATCHES" = 1 ]; then
    if [ -n "${MAX_PATCH_NUM:-}" ]; then
        log "applying patches from $PATCHES_DIR (MAX_PATCH_NUM=$MAX_PATCH_NUM)"
    else
        log "applying patches from $PATCHES_DIR"
    fi
    filtered_patches | while read -r p; do
        log "  $(basename "$p")"
        ( cd "$SRC_DIR" && patch -p1 < "$p" >/dev/null )
    done
else
    log "SKIPPING patches/wine/ (APPLY_FUSION_PATCHES=$APPLY_FUSION_PATCHES) — set =1 to re-enable"
fi

mkdir -p "$BUILD_DIR"

# ccache wrap — separate CC vars per arch. ~5min → ~30s warm-cache rebuilds.
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
