#!/bin/sh
# Builds both Linux releases for the host architecture and archives them:
#
#   telar-linux-ARCH.tar.gz            native client, needs a desktop
#   telar-linux-ARCH-headless.tar.gz   runtime and CLI without a window, for servers
#
#   packaging/release/linux.sh OUT_DIR
#
# Asset names carry no version, so releases/latest/download/NAME always
# resolves; install.sh relies on it.
#
# The headless release is the C++ runtime and CLI. TELAR_RUNTIME_DISTRIBUTABLE
# links every library but glibc statically, so it runs on any glibc Linux at
# or above the builder's glibc; check-linkage fails the build otherwise. It
# needs the static development packages install-linux-deps.sh lists, Zig 0.17
# for libghostty-vt (ZIG_GHOSTTY, default zig) and Cargo for the diagram
# renderer. GHOSTTY_VT_ROOT names an existing libghostty-vt build instead.
#
# The desktop release is still the Zig build until the C++ GUI ships its Qt
# libraries in a Linux archive. It keeps the host OS so pkg-config and the
# distribution's Wayland, Vulkan and ATK libraries resolve, and pins the CPU
# to the architecture's baseline so any machine runs it. It needs the glibc
# of the runner that built it: Ubuntu 24.04's headers turn strtol into
# __isoc23_strtol, a glibc 2.38 symbol. The checks below fail the build if a
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

gui=telar-linux-$arch
headless=telar-linux-$arch-headless
cd "$root"
zig build -Doptimize=ReleaseFast -Dstrip=true -Dcpu=baseline --prefix "$work/$gui"
TELAR_GLIBC_MAX=$glibc_max "$root/packaging/release/check-linkage.sh" linux-gui "$work/$gui/bin/telar" "$work/$gui/bin/telar-diagram-renderer"
"$work/$gui/bin/telar" --version

ghostty=${GHOSTTY_VT_ROOT:-$work/ghostty}
if [ -z "${GHOSTTY_VT_ROOT:-}" ]; then
    python3 "$root/services/runtime-cpp/tools/build_ghostty.py" --zig "${ZIG_GHOSTTY:-zig}" --build-dir "$work/ghostty-build" --prefix "$ghostty"
fi

cmake -S "$root/services/runtime-cpp" -B "$work/runtime" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DTELAR_RUNTIME_DISTRIBUTABLE=ON -DBUILD_TESTING=OFF -DGHOSTTY_VT_ROOT="$ghostty"
TELAR_GLIBC_MAX=$glibc_max cmake --build "$work/runtime" --target distributable-linkage
cmake --install "$work/runtime" --prefix "$work/$headless"
cargo build --release --locked --manifest-path "$root/tools/diagram-renderer/Cargo.toml" --target-dir "$work/renderer"
install -m 755 "$work/renderer/release/telar-diagram-renderer" "$work/$headless/bin/telar-diagram-renderer"
TELAR_GLIBC_MAX=$glibc_max "$root/packaging/release/check-linkage.sh" linux-server "$work/$headless/bin/telar-diagram-renderer"
"$work/$headless/bin/telar" --version

for name in "$gui" "$headless"; do
    tar -czf "$out/$name.tar.gz" -C "$work" "$name"
done
