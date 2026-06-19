#!/bin/bash
# Apply the fusion-box binary patch to Fusion's bundled Qt6WebEngineCore.dll.
#
# Purpose: force Chromium's `RenderProcessHost::run_renderer_in_process()`
# getter to always return true. With it true, Chromium's spawn-renderer
# decision in `RenderProcessHostImpl::Init` (and elsewhere) takes the
# in-process path, eliminating the Chromium renderer-subprocess. Renderer
# HWNDs then live in Fusion main's wine process, so wine's
# winewayland.drv can resolve their toplevel `wayland_surface` and the
# Data Panel renders correctly. See docs/qt6webengine-binary-patch.md.
#
# THIS IS A TEMPLATE. The PATCH_OFFSET/PATCH_BYTES values are placeholders
# until the radare2/Ghidra investigation in
# debug/ghidra-scripts/find_render_process_host.py identifies the exact
# function body to overwrite. Until then this script refuses to patch.
#
# Idempotent: makes a one-time backup at <dll>.fusion-box-orig and checks
# whether the patch is already applied before re-running. Re-run safely
# after Fusion auto-update: the wrapper detects a new DLL hash and refuses
# to apply (the patch site may have moved); rerun the investigation flow.

set -euo pipefail

PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
WEBDEPLOY="$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"

INSTALL_DIR=$(find "$WEBDEPLOY" -maxdepth 1 -mindepth 1 -type d \
    -exec test -e {}/Qt6WebEngineCore.dll \; -print 2>/dev/null | head -1)
if [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: no Qt6WebEngineCore.dll under $WEBDEPLOY" >&2
    exit 1
fi
DLL="$INSTALL_DIR/Qt6WebEngineCore.dll"
BACKUP="$DLL.fusion-box-orig"

# --- patch metadata (TO BE FILLED IN by the investigation) -------------------
# DLL_SHA256: hash of the unpatched DLL we built the offsets against. Used
# as a guard against applying the patch to a different Fusion version.
DLL_SHA256_EXPECTED="PLACEHOLDER-fill-in-after-investigation"

# PATCH_OFFSET: byte offset into the DLL (file offset, NOT virtual address)
# where the getter function body starts.
PATCH_OFFSET="PLACEHOLDER"

# PATCH_BYTES_ORIG: the bytes we expect to see at PATCH_OFFSET before
# patching (verifies we're patching the right place).
PATCH_BYTES_ORIG="PLACEHOLDER"

# PATCH_BYTES_NEW: the bytes we write. `b0 01 c3` = `mov al, 0x01; ret`
# (forces `run_renderer_in_process()` to return true). Pad with `90`
# (nop) to match the original body length so RIP-relative neighbors
# stay aligned.
PATCH_BYTES_NEW="PLACEHOLDER"
# -----------------------------------------------------------------------------

if [[ "$DLL_SHA256_EXPECTED" == PLACEHOLDER* ]]; then
    echo "ERROR: patch metadata not filled in yet. Run the Ghidra investigation:"
    echo "  bash debug/ghidra-analyze-qt6webengine.sh   # 1-2h initial analysis"
    echo "  /opt/ghidra/support/analyzeHeadless ~/ghidra-projects fusion-box \\"
    echo "      -process Qt6WebEngineCore.dll \\"
    echo "      -scriptPath debug/ghidra-scripts \\"
    echo "      -postScript find_render_process_host.py"
    echo "Then fill in PATCH_OFFSET / PATCH_BYTES_* in this script."
    exit 1
fi

ACTUAL_SHA=$(sha256sum "$DLL" | cut -d' ' -f1)

# Detect "already patched" by comparing current bytes at PATCH_OFFSET.
read_bytes_at() {
    dd if="$1" bs=1 skip="$2" count="${3:-${#PATCH_BYTES_NEW}}" status=none 2>/dev/null | xxd -p | tr -d '\n'
}
NEW_BYTES_NORM=$(echo "$PATCH_BYTES_NEW" | tr -d ' ')
ORIG_BYTES_NORM=$(echo "$PATCH_BYTES_ORIG" | tr -d ' ')
CURRENT=$(read_bytes_at "$DLL" "$((PATCH_OFFSET))" "$((${#NEW_BYTES_NORM} / 2))")

if [ "$CURRENT" = "$NEW_BYTES_NORM" ]; then
    echo "[patch-qt6we] Already patched (current bytes match PATCH_BYTES_NEW). Nothing to do."
    exit 0
fi

if [ "$CURRENT" != "$ORIG_BYTES_NORM" ]; then
    echo "ERROR: unexpected bytes at offset $PATCH_OFFSET in $DLL"
    echo "  expected: $ORIG_BYTES_NORM"
    echo "  actual:   $CURRENT"
    if [ "$ACTUAL_SHA" != "$DLL_SHA256_EXPECTED" ]; then
        echo ""
        echo "DLL hash mismatch (likely Fusion auto-updated since the patch was authored)."
        echo "  expected: $DLL_SHA256_EXPECTED"
        echo "  actual:   $ACTUAL_SHA"
        echo "Re-run the Ghidra investigation to find new offsets."
    fi
    exit 1
fi

# Backup before first patch (skip if backup already exists).
if [ ! -f "$BACKUP" ]; then
    echo "[patch-qt6we] backing up $DLL -> $BACKUP"
    cp -p "$DLL" "$BACKUP"
fi

# Apply the patch.
echo "[patch-qt6we] writing $((${#NEW_BYTES_NORM} / 2)) bytes at offset $PATCH_OFFSET"
printf '%s' "$NEW_BYTES_NORM" | xxd -r -p | dd of="$DLL" bs=1 seek="$((PATCH_OFFSET))" \
    count="$((${#NEW_BYTES_NORM} / 2))" conv=notrunc status=none

# Verify.
POST=$(read_bytes_at "$DLL" "$((PATCH_OFFSET))" "$((${#NEW_BYTES_NORM} / 2))")
if [ "$POST" != "$NEW_BYTES_NORM" ]; then
    echo "ERROR: post-patch verify failed"
    echo "  wanted: $NEW_BYTES_NORM"
    echo "  read:   $POST"
    exit 1
fi
echo "[patch-qt6we] patch applied OK. Backup at $BACKUP"
