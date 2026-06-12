#!/bin/bash
# Build a patched Qt 6.8.3 (qtbase only) cross-compiled for Windows.
#
# Why: some Fusion-on-winewayland bugs trace to Qt's deferred paint/layout
# scheduling - the wine layer can't synchronously force Qt to repaint when
# a wayland configure event arrives, so wine flushes a partial buffer and
# user-visible artifacts result (timeline disappearance on vertical shrink,
# navbar blank-white). The fix is in Qt itself - specifically
# qtbase/src/plugins/platforms/windows/qwindowswindow.cpp's WM_SIZE handler -
# but the binary patch surface is too large to mod, so we cross-build qtbase
# from source with our patches under patches/qt/ and drop the resulting
# Qt6Gui.dll / Qt6Widgets.dll / qwindows.dll into Fusion's webdeploy directory.
#
# Cross-build approach (two-stage; Arch's qt6-base is 6.11.x which has CMake
# macros incompatible with 6.8.3 - can't use it as QT_HOST_PATH directly):
#   Stage 1: Build a host (Linux) qtbase 6.8.3 from the same source - just
#     enough to produce moc / rcc / syncqt for the cross-build to consume.
#     Bootstrap-only feature set; installed under $CACHE_DIR/host-install/.
#   Stage 2: Cross-build qtbase 6.8.3 for Windows via mingw-w64, pointing
#     QT_HOST_PATH at the stage-1 host install.
#   We build qtbase only - no qtdeclarative (QML, ~30 min), no qtwebengine
#   (Chromium fork, ~6 hours and not relevant to our bug class), no qttools.
#
# Idempotent: re-runs cheap if the install dir already exists and its patch
# stamp matches the current patches/qt/ contents. Force a rebuild with
# `BUILD_QT_FORCE=1`. Patch sha256s are stamped just like build-wine.sh.

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

# Compute a stamp of (Qt version + sha256 of all patches in order). Lets us
# skip rebuilds when nothing has changed - same approach as build-wine.sh.
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

# mingw-w64 cross toolchain file. Same conventions Arch + Fedora use.
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

# Stage 1: host build. We can't use Arch's /usr Qt because it's 6.11.x and
# 6.8.3's CMake config files reference _qt_internal_should_include_targets
# macros that don't exist in newer Qt. Building 6.8.3 host-native (Linux gcc)
# from the same tarball gives a version-matched moc / rcc / syncqt plus all
# the other "Qt6FooTools" packages the cross-build references (qdbuscpp2xml,
# qvkgen, etc). We keep tests + examples off to keep this stage manageable
# but otherwise build with default features so every host tool the cross-
# build might want is available.
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

# Stage 2: cross-build for Windows. Point QT_HOST_PATH at our stage-1 host
# install so we get the matching 6.8.3 moc/rcc/syncqt instead of Arch's 6.11.x.
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
