#!/bin/sh
# Builds the Linux desktop release for the host architecture and archives it:
#
#   telar-linux-ARCH.tar.gz   native client, needs a desktop
#
#   packaging/release/linux.sh OUT_DIR
#
# The headless release builds on Alpine with linux-headless.sh. Asset names
# carry no version, so releases/latest/download/NAME always resolves;
# install.sh relies on it.
#
# The desktop release is still the Zig build until the C++ GUI ships its Qt
# libraries in a Linux archive. It keeps the host OS so pkg-config and the
# distribution's Wayland, Vulkan and ATK libraries resolve, and pins the CPU
# to the architecture's baseline so any machine runs it. It needs the glibc
# of the runner that built it: Ubuntu 24.04's headers turn strtol into
# __isoc23_strtol, a glibc 2.38 symbol. The check below fails the build if a
# runner update raises that floor unnoticed.
set -eu

out=$1
glibc_max=2.38
root=$(cd "$(dirname "$0")/../.." && pwd)
arch=$(uname -m)
case $arch in
    x86_64 | aarch64) ;;
    arm64) arch=aarch64 ;;
    *)
        printf 'linux.sh: unsupported architecture %s\n' "$arch" >&2
        exit 1
        ;;
esac

mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

name=telar-linux-$arch
cd "$root"
zig build -Doptimize=ReleaseFast -Dstrip=true -Dcpu=baseline --prefix "$work/$name"
TELAR_GLIBC_MAX=$glibc_max "$root/packaging/release/check-linkage.sh" linux-gui "$work/$name/bin/telar" "$work/$name/bin/telar-diagram-renderer"
"$work/$name/bin/telar" --version
tar -czf "$out/$name.tar.gz" -C "$work" "$name"
