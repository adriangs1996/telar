#!/bin/sh
# Builds the Linux headless release for the host architecture on Alpine:
#
#   telar-linux-ARCH-headless.tar.gz   runtime and CLI without a window, for servers
#
#   packaging/release/linux-headless.sh OUT_DIR    # after install-alpine-deps.sh
#
# The C++ runtime, CLI, configuration checker and diagram renderer link
# statically against musl, so the archive starts on any Linux, Alpine and
# older glibc distributions included, and needs no library of the host.
# check-linkage fails the build if any executable asks for one. It builds
# with the pinned LLVM/libc++ source bootstrap on musl; all native application
# libraries are managed from source without distro GCC LTO objects. It needs
# the shared pinned Zig/libghostty-vt bootstrap, or GHOSTTY_VT_ROOT
# naming an existing verified build.
set -eu

out=$1
root=$(cd "$(dirname "$0")/../.." && pwd)
arch=$(uname -m)
case $arch in
    x86_64 | aarch64) ;;
    *)
        printf 'linux-headless.sh: unsupported architecture %s\n' "$arch" >&2
        exit 1
        ;;
esac

mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
name=telar-linux-$arch-headless

ghostty=${GHOSTTY_VT_ROOT:-}
if [ -z "${GHOSTTY_VT_ROOT:-}" ]; then
    ghostty=$("$root/tools/cpp" vt | tail -n 1)
fi

"$root/tools/cpp" exec -- cmake -S "$root/src/runtime-cpp" -B "$work/runtime" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$root/.toolchain/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release -DTELAR_RUNTIME_DISTRIBUTABLE=ON -DBUILD_TESTING=OFF -DGHOSTTY_VT_ROOT="$ghostty"
"$root/tools/cpp" exec -- cmake --build "$work/runtime" --target distributable-linkage
"$root/tools/cpp" exec -- cmake --install "$work/runtime" --prefix "$work/$name"

# An explicit target keeps crt-static off the build scripts and proc macros.
host=$(rustc -vV | sed -n 's/^host: //p')
RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --locked --target "$host" \
    --manifest-path "$root/tools/diagram-renderer/Cargo.toml" --target-dir "$work/renderer"
install -m 755 "$work/renderer/$host/release/telar-diagram-renderer" "$work/$name/bin/telar-diagram-renderer"
"$root/packaging/release/check-linkage.sh" linux-headless "$work/$name/bin/telar-diagram-renderer"
"$work/$name/bin/telar" --version

tar -czf "$out/$name.tar.gz" -C "$work" "$name"
