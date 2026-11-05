#!/bin/sh
# Installs what the Linux headless release needs on Alpine: GCC, CMake,
# Ninja, Perl, flex and bison to build the pinned native libraries, what Zig needs
# to build libghostty-vt, and the Rust toolchain (RUST_TOOLCHAIN, default
# 1.93.1) through rustup, since Alpine's own Rust lags behind it.
#
#   packaging/release/install-alpine-deps.sh     # as root
#   . "$HOME/.cargo/env"
set -eu

apk add --no-cache build-base cmake ninja python3 perl flex bison git linux-headers curl xz rustup
rustup-init -y -q --profile minimal --default-toolchain "${RUST_TOOLCHAIN:-1.93.1}"
