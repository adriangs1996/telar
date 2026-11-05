#!/bin/sh
# Installs what building the C++ desktop client and its private Qt needs on
# Ubuntu 24.04, the release runners' system: GCC 14, CMake and Ninja, the X11,
# xcb, Wayland, xkbcommon, Fontconfig, EGL and D-Bus headers Qt's platform
# plugins link against, the Vulkan headers for its Vulkan renderer, and
# patchelf and binutils to make the packaged tree relocatable.
#
#   sudo packaging/release/install-linux-deps.sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl xz-utils git python3 patch file binutils patchelf \
    cmake ninja-build make perl flex bison g++-14 pkg-config \
    libfontconfig1-dev libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev \
    libxi-dev libxrender-dev libxcb1-dev libxcb-cursor-dev libxcb-glx0-dev \
    libxcb-keysyms1-dev libxcb-image0-dev libxcb-render0-dev libxcb-render-util0-dev \
    libxcb-randr0-dev libxcb-icccm4-dev libxcb-shape0-dev libxcb-shm0-dev \
    libxcb-sync-dev libxcb-util-dev libxcb-xfixes0-dev libxcb-xkb-dev \
    libxkbcommon-dev libxkbcommon-x11-dev libwayland-dev wayland-protocols \
    libegl1-mesa-dev libgl1-mesa-dev libvulkan-dev libdbus-1-dev
