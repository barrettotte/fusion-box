FROM docker.io/library/archlinux:latest

# Arch moved wine to pure WoW64 in 2025 — no multilib needed.
RUN echo "==> phase 1/10: syncing package db + upgrading base image (~2 min)" && \
    pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman -Syu --noconfirm

# distrobox-init runtime deps.
RUN echo "==> phase 2/10: installing distrobox runtime deps" && \
    pacman -Sy --noconfirm --needed \
        base-devel \
        git \
        sudo \
        shadow \
        inetutils \
        less \
        wget \
        curl \
        diffutils \
        findutils \
        gnupg \
        pinentry \
        xdg-utils \
        ncurses

# Toolchain for building patched wine from source.
#   mingw-w64: wine PE-side build (x86_64-w64-mingw32-gcc).
#   python: wine-staging patchinstall.py (USE_STAGING=1 path).
#   ccache: wraps wine builds; ~5min → ~30s warm rebuilds.
RUN echo "==> phase 3/10: installing wine build toolchain (mingw + ccache + python)" && \
    pacman -Sy --noconfirm --needed \
        mingw-w64-gcc \
        mingw-w64-headers \
        mingw-w64-winpthreads \
        ccache \
        python

# wine-staging: baseline binary (webview2-test A/B harness targets /usr/bin/wine-staging).
# wine-mono + wine-gecko: MSI runtimes our patched wine picks up on prefix init.
# winetricks: used by install-fusion.sh to drop DXVK into the wineprefix.
RUN echo "==> phase 4/10: installing wine runtime (staging + mono + gecko + winetricks)" && \
    pacman -Sy --noconfirm --needed \
        wine-staging \
        wine-mono \
        wine-gecko \
        winetricks

# Vulkan loader (Fusion+DXVK runtime) + vulkan-tools (vulkaninfo for user GPU troubleshooting).
# Host NVIDIA ICD is injected by distrobox --nvidia.
RUN echo "==> phase 5/10: installing Vulkan runtime" && \
    pacman -Sy --noconfirm --needed \
        vulkan-icd-loader \
        vulkan-tools

# Audio + GL client libs. WoW64, so no lib32-*.
RUN echo "==> phase 6/10: installing audio + GL runtime" && \
    pacman -Sy --noconfirm --needed \
        alsa-lib \
        libpulse \
        libgl

# Fusion installer requirements.
RUN echo "==> phase 7/10: installing Fusion installer deps" && \
    pacman -Sy --noconfirm --needed \
        cabextract \
        p7zip \
        unzip

# Fonts (corefonts installed per-prefix via winetricks).
RUN echo "==> phase 8/10: installing fonts" && \
    pacman -Sy --noconfirm --needed \
        ttf-liberation \
        ttf-dejavu \
        noto-fonts \
        noto-fonts-cjk \
        noto-fonts-emoji

# xdg-open shim — the stock one detects KDE via inherited XDG_CURRENT_DESKTOP
# and tries kde-open (not installed here); forward to host instead so wine's
# ShellExecute("https://...") reaches the host browser.
RUN echo "==> phase 9/10: installing xdg-open shim" && \
    printf '#!/bin/bash\nexec distrobox-host-exec xdg-open "$@"\n' > /usr/local/bin/xdg-open && chmod +x /usr/local/bin/xdg-open

RUN echo "==> phase 10/10: cleaning pacman cache" && \
    pacman -Scc --noconfirm

LABEL org.opencontainers.image.title=fusion-box
LABEL org.opencontainers.image.description="Autodesk Fusion 360 under patched wine 11.10 (winewayland.drv) + DXVK"
