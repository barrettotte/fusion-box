#!/bin/bash
# Build a patched wine for fusion-box.
#
# Builds mainline wine 11.10 + our 10 fusion-box patches by default.
#
# The wine-staging path (USE_STAGING=1) is also supported — wine-staging carries
# ~250 experimental patches including Zhiyi Zhang's (CodeWeavers) 65-patch
# DirectComposition implementation. **The Data Panel rendering bug we spent
# weeks chasing turned out to be PREFIX-STATE POLLUTION, not missing DComp**:
# fresh Fusion install in a clean wineprefix renders the Data Panel under
# vanilla wine 11.10 fine. The wine-staging code path remains here for
# diagnostic A/B testing and as a fallback if a future Fusion bug genuinely
# needs broader compat patches.
# See docs/data-panel-pioneering-roadmap.md for the full investigation.
#
# Env vars:
#   USE_STAGING=1 → fetch wine-staging + apply ~250 staging patches before
#                   our fusion-box patches. Default 0 (mainline). Useful for
#                   A/B testing or if wine-staging's broader compat is needed.
#   APPLY_FUSION_PATCHES=0 → skip patches/wine/*.patch. Default 1 (apply).
#                            Use to A/B against unpatched wine.
#   BUILD_WINE_FORCE=1 → force rebuild even if stamp matches.
#   USE_CCACHE=0 → disable ccache wrapping.
#   MAX_PATCH_NUM=N → bisect: apply only patches/wine/ with numeric prefix <= N.
#                     Used to find which of our patches introduces a regression.
#
# Idempotent: re-runs cheap if the install dir already exists and its patch
# stamp matches the current state (wine version + staging-on/off + applied
# patch sha256 list). Force a rebuild with `BUILD_WINE_FORCE=1`.

set -euo pipefail

WINE_VERSION="11.10"
WINE_SRC_URL="https://dl.winehq.org/wine/source/11.x/wine-${WINE_VERSION}.tar.xz"

# Wine-staging matching this wine version. Pinned to a specific git tag so
# fresh checkouts are reproducible (no surprise updates from upstream).
# Default off (USE_STAGING=0) because mainline wine 11.10 + our patches is
# sufficient for Fusion; opt in if testing or if broader staging compat
# patches are needed for a future investigation.
USE_STAGING="${USE_STAGING:-0}"
WINE_STAGING_TAG="v${WINE_VERSION}"
WINE_STAGING_REPO="https://gitlab.winehq.org/wine/wine-staging.git"

# Apply our 10 fusion-box patches (default ON). Set =0 to test what
# unpatched wine looks like.
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

# Honour MAX_PATCH_NUM if set: emit only patches whose numeric prefix is <= the limit.
# Used to bisect which patch introduces a regression — `MAX_PATCH_NUM=0` builds vanilla,
# `MAX_PATCH_NUM=6` builds with patches 0001..0006.
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

# Compute a stamp of (wine version + staging on/off + sha256 of applied patches).
# Lets us skip rebuilds when nothing has changed.
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

# Fetch + apply wine-staging patches first (BEFORE our patches), if enabled.
# This brings in ~250 staging patches including Zhang's DComp implementation
# which is what makes modern Edge WebView2 render under wine.
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
    # patchinstall.py is the official wine-staging tool that applies the full
    # patch series in the right order. --backend=patch keeps it portable.
    python3 "$STAGING_DIR/staging/patchinstall.py" --all DESTDIR="$SRC_DIR" \
        --backend=patch > "$CACHE_DIR/staging-patchinstall.log" 2>&1
    log "wine-staging patchset applied (log: $CACHE_DIR/staging-patchinstall.log)"
fi

# Apply our fusion-box-specific patches on top of staging (or vanilla wine if
# USE_STAGING=0). Skipped by default per APPLY_FUSION_PATCHES=0 — flip to 1
# once wine-staging is verified end-to-end with Fusion.
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
