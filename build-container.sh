#!/bin/bash
# Build the fusion-box container image and create the distrobox.
#
# Usage:
#   ./build-container.sh                 # build + create with no extras
#   ./build-container.sh --nvidia        # build + create with NVIDIA GPU
#   ./build-container.sh --recreate      # destroy existing container first
#
# Env vars (optional):
#   BOX_HOME=/path/to/dir   bind-mount this dir as the container's $HOME instead of the host $HOME.
#                           Useful for isolating Fusion's wineprefix + wine builds from the rest of $HOME
#                           (so you can wipe / back up / share separately).
#                           Equivalent to passing `--home $BOX_HOME` to `distrobox create`.
#
# Any extra args (other than --recreate) are passed through to `distrobox create`.

set -euo pipefail
cd "$(dirname "$0")"
REPO_DIR="$(pwd)"

IMAGE=localhost/fusion-box:latest
NAME=fusion-box

RECREATE=0
PASS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --recreate) RECREATE=1 ;;
        *) PASS_ARGS+=("$arg") ;;
    esac
done

# Translate BOX_HOME into a --home flag. If the user passed --home explicitly, their flag wins and we don't add a duplicate.
if [ -n "${BOX_HOME:-}" ]; then
    if printf '%s\n' "${PASS_ARGS[@]}" | grep -qx -- '--home'; then
        echo "==> Both BOX_HOME and --home given; --home wins"
    else
        echo "==> Using BOX_HOME=$BOX_HOME as the container's \$HOME"
        mkdir -p "$BOX_HOME"
        PASS_ARGS+=(--home "$BOX_HOME")
    fi
fi

echo "==> Building image $IMAGE"
podman build -t "$IMAGE" -f Containerfile .

if distrobox list 2>/dev/null | awk '{print $3}' | grep -qx "$NAME"; then
    if [ "$RECREATE" = 1 ]; then
        echo "==> Removing existing container $NAME"
        distrobox rm -f "$NAME"
    else
        echo "==> Container $NAME already exists. Re-run with --recreate to replace."
        exit 0
    fi
fi

echo "==> Creating container $NAME (args: ${PASS_ARGS[*]:-none})"
distrobox create --image "$IMAGE" --name "$NAME" "${PASS_ARGS[@]}"

cat <<EOF

Container ready. Next steps:
  1. Build the patched wine (~3 min):
       distrobox enter $NAME -- bash $REPO_DIR/scripts/build-wine.sh

  2. Install Fusion 360 (~30-45 min, ~5.6 GB download):
       distrobox enter $NAME -- bash $REPO_DIR/scripts/install-fusion.sh

  3. Launch Fusion:
       distrobox enter $NAME -- bash $REPO_DIR/scripts/launch-fusion.sh

  4. (One-time, host-side) Install adskidmgr:// URL handler so OAuth sign-in can call back from host browser into container:
       bash $REPO_DIR/scripts/install-host-handler.sh
EOF
