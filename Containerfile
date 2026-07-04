FROM docker.io/library/archlinux:latest

# Arch moved wine to pure WoW64 in 2025 — no multilib needed.
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman -Syu --noconfirm

# distrobox-init runtime deps.
# TODO: drop xorg-xauth, xorg-xkbcomp when XWayland is fully out of the picture.
RUN pacman -Sy --noconfirm --needed \
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
        xorg-xauth \
        xorg-xkbcomp \
        ncurses

# Toolchain for RE + wine/Qt cross-builds.
#   radare2 / ghidra + jdk21: inspect Autodesk PE binaries + Chromium code in
#     Qt6WebEngineCore.dll (r2 for quick probes, ghidra for the big ones).
#   mingw-w64: cross-compile helper DLLs + Qt 6.8.3 for Windows.
#   cmake / ninja / python / qt6-base: Qt cross-build (host moc/rcc via QT_HOST_PATH).
#   ccache: wraps wine builds; ~5min → ~30s warm rebuilds.
RUN pacman -Sy --noconfirm --needed \
        mingw-w64-gcc \
        mingw-w64-headers \
        mingw-w64-winpthreads \
        radare2 \
        ghidra \
        jdk21-openjdk \
        ccache \
        cmake \
        ninja \
        python \
        python-capstone \
        python-pefile \
        qt6-base

# wine-staging (baseline; scripts/build-wine.sh replaces with patched 11.10).
# DXVK/vkd3d-proton get installed per-prefix by install-fusion.sh (winetricks).
RUN pacman -Sy --noconfirm --needed \
        wine-staging \
        wine-mono \
        wine-gecko \
        winetricks

# Vulkan loader only — host NVIDIA ICD injected by distrobox --nvidia.
RUN pacman -Sy --noconfirm --needed \
        vulkan-tools \
        vulkan-icd-loader

# Audio + GL client libs. WoW64, so no lib32-*.
# TODO: alsa-plugins needed?
RUN pacman -Sy --noconfirm --needed \
        alsa-lib \
        alsa-plugins \
        libpulse \
        libgl

# Fusion installer requirements.
RUN pacman -Sy --noconfirm --needed \
        cabextract \
        p7zip \
        unzip

# Fonts (corefonts installed per-prefix via winetricks).
RUN pacman -Sy --noconfirm --needed \
        ttf-liberation \
        ttf-dejavu \
        noto-fonts \
        noto-fonts-cjk \
        noto-fonts-emoji

# xdg-open shim — the stock one detects KDE via inherited XDG_CURRENT_DESKTOP
# and tries kde-open (not installed here); forward to host instead so wine's
# ShellExecute("https://...") reaches the host browser.
RUN printf '#!/bin/bash\nexec distrobox-host-exec xdg-open "$@"\n' > /usr/local/bin/xdg-open && chmod +x /usr/local/bin/xdg-open

RUN pacman -Scc --noconfirm

LABEL org.opencontainers.image.title=fusion-box
LABEL org.opencontainers.image.description="Autodesk Fusion 360 under patched wine 11.10 (winewayland.drv) + DXVK"
