#!/bin/bash
# Run Ghidra headless analysis on Fusion's bundled Qt6WebEngineCore.dll.
#
# Imports the DLL into a persistent Ghidra project (cached under
# ~/.cache/fusion-box/ghidra-projects/) and runs auto-analysis. The project
# survives container restarts and across investigation sessions, so subsequent
# queries are fast (no re-analysis needed).
#
# Initial analysis takes 1-2+ hours for the 148MB DLL. Idempotent: re-runs
# detect an existing project and skip import; pass FORCE_REIMPORT=1 to redo
# from scratch (e.g., after a Fusion auto-update changes the DLL).
#
# After analysis completes, query the project with scripts under
# debug/ghidra-scripts/ via the analyzeHeadless `-process` mode. Example:
#   distrobox enter fusion-box -- \
#       /opt/ghidra/support/analyzeHeadless \
#           ~/.cache/fusion-box/ghidra-projects fusion-box \
#           -process Qt6WebEngineCore.dll \
#           -postScript find_render_process_host.py
#
# Background: investigating the Data Panel render bug. Patch site is somewhere
# in Chromium-122 code inside the DLL (Qt code does NOT strip --single-process;
# verified via debug/capture-process-tree.sh comparing baseline vs sp runs).
# See docs/qt6webengine-binary-patch.md for full investigation log.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
WEBDEPLOY="$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"

# Locate the currently-installed Qt6WebEngineCore.dll (Fusion auto-update may
# move the hash-dir; always find the freshest).
INSTALL_DIR=$(find "$WEBDEPLOY" -maxdepth 1 -mindepth 1 -type d \
    -exec test -e {}/Qt6WebEngineCore.dll \; -print 2>/dev/null | head -1)
if [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: no Qt6WebEngineCore.dll under $WEBDEPLOY" >&2
    exit 1
fi
DLL="$INSTALL_DIR/Qt6WebEngineCore.dll"

# Ghidra rejects project paths containing '.'-prefixed elements (NamingUtilities),
# so we can't use ~/.cache/. Put projects directly under $HOME instead.
PROJECT_DIR="$HOME/ghidra-projects"
PROJECT_NAME="fusion-box"
GHIDRA_HEADLESS=/opt/ghidra/support/analyzeHeadless
SCRIPTS_DIR="$REPO_DIR/debug/ghidra-scripts"

mkdir -p "$PROJECT_DIR"
mkdir -p "$SCRIPTS_DIR"

PROJECT_FILE="$PROJECT_DIR/$PROJECT_NAME.gpr"
IMPORTED_MARKER="$PROJECT_DIR/.qt6webengine-imported"
DLL_HASH=$(sha256sum "$DLL" | cut -d' ' -f1)
DLL_HASH_FILE="$PROJECT_DIR/.qt6webengine-hash"

echo "[ghidra-analyze] DLL: $DLL (sha256 ${DLL_HASH:0:16}...)"
echo "[ghidra-analyze] Project: $PROJECT_FILE"

# Skip re-import if the project already contains this exact DLL.
if [ "${FORCE_REIMPORT:-0}" != 1 ] \
   && [ -f "$PROJECT_FILE" ] \
   && [ -f "$DLL_HASH_FILE" ] \
   && [ "$(cat "$DLL_HASH_FILE")" = "$DLL_HASH" ] \
   && [ -f "$IMPORTED_MARKER" ]; then
    echo "[ghidra-analyze] Project already contains this DLL (hash match)."
    echo "[ghidra-analyze] Skipping import + analysis. Set FORCE_REIMPORT=1 to redo."
    echo "[ghidra-analyze] Query with:"
    echo "  $GHIDRA_HEADLESS '$PROJECT_DIR' $PROJECT_NAME \\"
    echo "      -process 'Qt6WebEngineCore.dll' \\"
    echo "      -scriptPath '$SCRIPTS_DIR' \\"
    echo "      -postScript <script.py>"
    exit 0
fi

echo "[ghidra-analyze] Starting import + auto-analysis."
echo "[ghidra-analyze] Logging to /tmp/ghidra-analyze-qt6we.log"

# 16G heap. The 2G default GC-thrashed (analysis stalled after 22min); 16G is
# the practical ceiling that still fits comfortably on a 62G host alongside
# Fusion testing. Going higher (32G+) helps marginally; cheaper to skip the
# heaviest analyzers (preanalysis_disable_slow.py preScript below).
export GHIDRA_HEADLESS_MAXMEM=16G

# Disable the slowest analyzers (Decompiler Parameter ID, Aggressive Instruction
# Finder, Stack, etc.) via preScript. For 148MB Chromium-embedded binaries
# these contribute most of the wall-clock time and we don't need them for
# function-discovery / xref / on-demand-decompile workflows.
"$GHIDRA_HEADLESS" "$PROJECT_DIR" "$PROJECT_NAME" \
    -import "$DLL" \
    -overwrite \
    -scriptPath "$SCRIPTS_DIR" \
    -preScript preanalysis_disable_slow.py \
    -log /tmp/ghidra-analyze-qt6we.log \
    2>&1 | tail -50

echo "$DLL_HASH" > "$DLL_HASH_FILE"
touch "$IMPORTED_MARKER"

echo "[ghidra-analyze] Done. Project at $PROJECT_FILE"
echo "[ghidra-analyze] Query with -process + -postScript (see top-of-file comment)."
