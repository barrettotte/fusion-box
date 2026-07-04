#!/bin/bash
# Cross-build patched Qt 6.8.3 (qtbase only) for Windows via mingw-w64.
# Two stage: host (Linux) qtbase for moc/rcc, then cross-build for Windows.
# Idempotent — sha256-stamps patches. Force with BUILD_QT_FORCE=1.

set -euo pipefail

QT_VERSION="6.8.3"
QT_SRC_URL="https://download.qt.io/archive/qt/6.8/${QT_VERSION}/submodules/qtbase-everywhere-src-${QT_VERSION}.tar.xz"
INSTALL_PREFIX="${QT_INSTALL_PREFIX:-$HOME/qt-versions/qt-${QT_VERSION}-fusion}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES_DIR="$REPO_DIR/patches/qt"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fusion-box/qt-build"
SRC_TARBALL="$CACHE_DIR/qtbase-${QT_VERSION}.tar.xz"
SRC_DIR="$CACHE_DIR/qtbase-everywhere-src-${QT_VERSION}"
HOST_BUILD_DIR="$SRC_DIR/build-host"
HOST_INSTALL_DIR="$CACHE_DIR/host-install"
BUILD_DIR="$SRC_DIR/build-win64"
TOOLCHAIN_FILE="$CACHE_DIR/mingw-w64-toolchain.cmake"
STAMP_FILE="$INSTALL_PREFIX/.fusion-box-build-stamp"

log() { echo "[$(date +%H:%M:%S)] $*"; }

expected_stamp() {
    {
        echo "qt=${QT_VERSION}"
        for p in "$PATCHES_DIR"/*.patch; do
            [ -f "$p" ] || continue
            echo "patch=$(basename "$p"):$(sha256sum "$p" | cut -d' ' -f1)"
        done
    } | sha256sum | cut -d' ' -f1
}

EXPECTED=$(expected_stamp)

if [ "${BUILD_QT_FORCE:-0}" != 1 ] && \
   [ -f "$INSTALL_PREFIX/bin/Qt6Widgets.dll" ] && \
   [ -f "$STAMP_FILE" ] && \
   [ "$(cat "$STAMP_FILE")" = "$EXPECTED" ]; then
    log "already built (stamp matches at $STAMP_FILE)"
    ls "$INSTALL_PREFIX/bin/"*.dll 2>/dev/null | head -5
    exit 0
fi

mkdir -p "$CACHE_DIR"

if [ ! -f "$SRC_TARBALL" ]; then
    log "fetching Qt ${QT_VERSION} qtbase source (~80 MB)"
    curl -fSL -o "$SRC_TARBALL.tmp" "$QT_SRC_URL"
    mv "$SRC_TARBALL.tmp" "$SRC_TARBALL"
fi

cat > "$TOOLCHAIN_FILE" <<'EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(TOOLCHAIN_PREFIX x86_64-w64-mingw32)
set(CMAKE_C_COMPILER ${TOOLCHAIN_PREFIX}-gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}-g++)
set(CMAKE_RC_COMPILER ${TOOLCHAIN_PREFIX}-windres)
set(CMAKE_FIND_ROOT_PATH /usr/${TOOLCHAIN_PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

rm -rf "$SRC_DIR"
log "extracting source"
tar -xf "$SRC_TARBALL" -C "$CACHE_DIR"

log "applying patches from $PATCHES_DIR"
patches_applied=0
for p in "$PATCHES_DIR"/*.patch; do
    [ -f "$p" ] || continue
    log "  $(basename "$p")"
    ( cd "$SRC_DIR" && patch -p1 < "$p" >/dev/null )
    patches_applied=$((patches_applied + 1))
done
log "$patches_applied patch(es) applied"

# Stage 1: host build for version-matched moc/rcc/syncqt (system 6.11.x
# has incompatible CMake macros, can't be used as QT_HOST_PATH).
mkdir -p "$HOST_BUILD_DIR"
log "STAGE 1: configure host build (Linux x86_64, default features minus tests/examples)"
( cd "$HOST_BUILD_DIR" && cmake -G Ninja .. \
    -DCMAKE_INSTALL_PREFIX="$HOST_INSTALL_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_BUILD_TESTS=OFF \
    -DBUILD_TESTING=OFF \
    > configure.log 2>&1 ) || { tail -50 "$HOST_BUILD_DIR/configure.log"; exit 1; }

log "STAGE 1: build (host moc/rcc/syncqt only)"
( cd "$HOST_BUILD_DIR" && ninja > build.log 2>&1 ) || { tail -50 "$HOST_BUILD_DIR/build.log"; exit 1; }

log "STAGE 1: install host bootstrap to $HOST_INSTALL_DIR"
rm -rf "$HOST_INSTALL_DIR"
( cd "$HOST_BUILD_DIR" && ninja install > install.log 2>&1 )

# Stage 2: cross-build for Windows, using stage-1 host install as QT_HOST_PATH.
mkdir -p "$BUILD_DIR"
log "STAGE 2: configure mingw-w64 cross build"
( cd "$BUILD_DIR" && cmake -G Ninja .. \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DQT_HOST_PATH="$HOST_INSTALL_DIR" \
    -DBUILD_TESTING=OFF \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_BUILD_TESTS=OFF \
    > configure.log 2>&1 ) || { tail -50 "$BUILD_DIR/configure.log"; exit 1; }

log "STAGE 2: build (this takes a while - qtbase is ~20 minutes single-threaded, less with -j)"
( cd "$BUILD_DIR" && ninja > build.log 2>&1 ) || { tail -50 "$BUILD_DIR/build.log"; exit 1; }

log "STAGE 2: install to $INSTALL_PREFIX"
rm -rf "$INSTALL_PREFIX"
( cd "$BUILD_DIR" && ninja install > install.log 2>&1 )

echo "$EXPECTED" > "$STAMP_FILE"
log "done"
log "DLLs available under $INSTALL_PREFIX/bin"
ls "$INSTALL_PREFIX/bin/"*.dll 2>/dev/null | head -10
log ""
log "To install into Fusion:"
log "  cp $INSTALL_PREFIX/bin/Qt6{Core,Gui,Widgets}.dll \\"
log "     \"$HOME/.wine-fusion/drive_c/Program Files/Autodesk/webdeploy/production/<hash>/\""
log "  cp $INSTALL_PREFIX/plugins/platforms/qwindows.dll \\"
log "     \"$HOME/.wine-fusion/drive_c/Program Files/Autodesk/webdeploy/production/<hash>/QtPlugins/platforms/\""
