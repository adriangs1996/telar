#!/bin/sh
# Installs what the Linux headless release needs on Alpine: GCC, CMake,
# Ninja, the static libraries the C++ runtime and CLI link, what Zig needs
# to build libghostty-vt, and the Rust toolchain (RUST_TOOLCHAIN, default
# 1.93.1) through rustup, since Alpine's own Rust lags behind it.
#
#   packaging/release/install-alpine-deps.sh     # as root
#   . "$HOME/.cargo/env"
set -eu

apk add --no-cache build-base cmake ninja python3 git linux-headers curl xz rustup \
    openssl-dev openssl-libs-static nghttp2-dev nghttp2-static brotli-dev brotli-static \
    zstd-dev zstd-static sqlite-dev sqlite-static zlib-dev zlib-static libpcap-dev
rustup-init -y -q --profile minimal --default-toolchain "${RUST_TOOLCHAIN:-1.93.1}"
