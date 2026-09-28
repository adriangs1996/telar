#!/bin/sh
# Installs what building telar needs on Ubuntu 24.04, the release runners'
# system: Wayland, Vulkan, xkbcommon, Fontconfig and ATK headers for the
# native client, wayland-scanner and glslc to generate its sources, and a C
# linker for the Rust helpers. Ubuntu 24.04 ships wayland-protocols 1.45
# through noble-updates, which has every protocol the client generates.
#
#   sudo packaging/release/install-linux-deps.sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl xz-utils gcc libc6-dev pkg-config python3 binutils file \
    libwayland-dev wayland-protocols libxkbcommon-dev libfontconfig-dev libvulkan-dev glslc \
    libatk1.0-dev libatk-bridge2.0-dev libglib2.0-dev
