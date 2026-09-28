#!/bin/sh
# Builds both Linux releases for the host architecture and archives them:
#
#   telar-linux-ARCH.tar.gz            native client, needs a desktop
#   telar-linux-ARCH-headless.tar.gz   runtime without the window, for servers
#
#   packaging/release/linux.sh OUT_DIR
#
# Asset names carry no version, so releases/latest/download/NAME always
# resolves; install.sh relies on it.
#
# The desktop build keeps the host OS so pkg-config and the distribution's
# Wayland, Vulkan and ATK libraries resolve, and pins the CPU to the
# architecture's baseline so any machine runs it. It needs the glibc of the
# runner that built it: Ubuntu 24.04's headers turn strtol into
# __isoc23_strtol, a glibc 2.38 symbol. The check below fails the build if a
# runner update raises that floor unnoticed. The headless build links musl
# statically, so it runs on any Linux, Alpine included, and loads nothing.
set -eu

out=$1
gui_glibc_max=2.38
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

gui=telar-linux-$arch
headless=telar-linux-$arch-headless
cd "$root"
zig build -Doptimize=ReleaseFast -Dstrip=true -Dcpu=baseline --prefix "$work/$gui"
zig build -Doptimize=ReleaseFast -Dstrip=true -Dgui=false -Dtarget="$arch-linux-musl" --prefix "$work/$headless"

TELAR_GLIBC_MAX=$gui_glibc_max "$root/packaging/release/check-linkage.sh" linux-gui "$work/$gui/bin/telar" "$work/$gui/bin/telar-diagram-renderer"
"$root/packaging/release/check-linkage.sh" linux-headless "$work/$headless/bin/telar"
"$work/$gui/bin/telar" --version
"$work/$headless/bin/telar" --version

for name in "$gui" "$headless"; do
    tar -czf "$out/$name.tar.gz" -C "$work" "$name"
done
