#!/bin/sh
# Builds both Linux releases for the host architecture and archives them:
#
#   telar-linux-ARCH.tar.gz            native client, needs a desktop
#   telar-linux-ARCH-headless.tar.gz   runtime and TUI, for servers
#
#   packaging/release/linux.sh OUT_DIR
#
# Asset names carry no version, so releases/latest/download/NAME always
# resolves; install.sh relies on it.
#
# The desktop build keeps the host OS so pkg-config and the distribution's
# Wayland, Vulkan and ATK libraries resolve, and pins the CPU to the
# architecture's baseline so any machine runs it. The headless build is a
# foreign target pinned to glibc 2.28, so it links nothing but glibc.
set -eu

out=$1
glibc_floor=2.28
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
zig build -Doptimize=ReleaseFast -Dstrip=true -Dgui=false -Dtarget="$arch-linux-gnu.$glibc_floor" --prefix "$work/$headless"

"$root/packaging/release/check-linkage.sh" linux-gui "$work/$gui/bin/telar" "$work/$gui/bin/telar-diagram-renderer"
TELAR_GLIBC_MAX=$glibc_floor "$root/packaging/release/check-linkage.sh" linux-headless "$work/$headless/bin/telar"
"$work/$gui/bin/telar" --version
"$work/$headless/bin/telar" --version

for name in "$gui" "$headless"; do
    tar -czf "$out/$name.tar.gz" -C "$work" "$name"
done
