FROM docker.io/library/archlinux:latest

# keyring + full sync. No multilib: Arch moved wine to pure WoW64 in 2025,
# so wine-staging lives in extra and doesn't need lib32-* deps anymore.
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman -Syu --noconfirm

# distrobox-init runtime deps
# TODO: xorg-xauth, xorg-xkbcomp - remove after XWayland removed
RUN pacman -Sy --noconfirm --needed \
        base-devel \
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

# Debugging / reverse-engineering toolchain. radare2 is for inspecting Autodesk's bundled
# PE binaries (AdskIdentityManager.exe, IdIPCServer.dll, Nu*10.dll) when we have to dig into Fusion internals.
# mingw-w64 is for cross-compiling any DLL stubs we need to drop into the wineprefix.
# Both are heavyweight but invaluable when the bug is several layers deep.
# cmake + ninja: cross-build Qt 6.8.3 (qtbase) for Windows via mingw-w64. The Qt
# patches under patches/qt/ target qwindows.dll's WM_SIZE handler etc. and need
# a real Qt source rebuild, not a binary mod. python pulled in for Qt's syncqt
# and other build helpers. qt6-base on Arch supplies host moc/rcc/syncqt that
# Qt's cross-build invokes via QT_HOST_PATH=/usr; without it the build can't
# generate moc files for the cross target.
RUN pacman -Sy --noconfirm --needed \
        mingw-w64-gcc \
        mingw-w64-headers \
        mingw-w64-winpthreads \
        radare2 \
        cmake \
        ninja \
        python \
        qt6-base

# wine + winetricks. DXVK and vkd3d-proton are installed per-prefix by
# `winetricks dxvk` / `winetricks vkd3d` at prefix-init time (Phase 3 script);
# the system-wide AUR packages aren't worth the AUR-helper dependency since
# the DLLs only matter inside the prefix anyway.
RUN pacman -Sy --noconfirm --needed \
        wine-staging \
        wine-mono \
        wine-gecko \
        winetricks

# Vulkan loader (host NVIDIA driver + ICD injected at runtime by distrobox --nvidia,
# so we only need the loader headers/binaries, not mesa layers).
# Fusion is x64, so lib32 vulkan is deferred until DXVK 32-bit DLLs prove necessary.
RUN pacman -Sy --noconfirm --needed \
        vulkan-tools \
        vulkan-icd-loader

# Audio + GL client libs. WoW64 wine handles 32-bit Windows apps via a 64-bit Linux process, so no lib32-* needed.
# TODO: alsa-plugins needed?
RUN pacman -Sy --noconfirm --needed \
        alsa-lib \
        alsa-plugins \
        libpulse \
        libgl

# Fusion installer requirements
RUN pacman -Sy --noconfirm --needed \
        cabextract \
        p7zip \
        unzip

# Fonts (corefonts via winetricks at prefix-init time, not image)
RUN pacman -Sy --noconfirm --needed \
        ttf-liberation \
        ttf-dejavu \
        noto-fonts \
        noto-fonts-cjk \
        noto-fonts-emoji

# xdg-open shim that forwards to the host. The stock xdg-open in this image detects
# KDE (XDG_CURRENT_DESKTOP is inherited from the host) and tries to call kde-open, which isn't installed here.
# Without this shim, wine's ShellExecute("https://...") -> xdg-open chain fails silently,
# leaving Fusion's sign-in browser-launch unable to open the host browser.
RUN printf '#!/bin/bash\nexec distrobox-host-exec xdg-open "$@"\n' > /usr/local/bin/xdg-open && chmod +x /usr/local/bin/xdg-open

# pacman cache cleanup
RUN pacman -Scc --noconfirm

LABEL org.opencontainers.image.title=fusion-box
LABEL org.opencontainers.image.description="Autodesk Fusion 360 under patched wine 11.10 (winewayland.drv) + DXVK"
