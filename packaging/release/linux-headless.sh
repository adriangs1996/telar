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
# with Alpine's GCC: Alpine's static libraries carry GCC LTO objects, which
# Clang cannot link. It needs
# Zig 0.17 for libghostty-vt (ZIG_GHOSTTY, default zig), or GHOSTTY_VT_ROOT
# naming an existing build.
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

ghostty=${GHOSTTY_VT_ROOT:-$work/ghostty}
if [ -z "${GHOSTTY_VT_ROOT:-}" ]; then
    python3 "$root/services/runtime-cpp/tools/build_ghostty.py" --zig "${ZIG_GHOSTTY:-zig}" --build-dir "$work/ghostty-build" --prefix "$ghostty"
fi

CC=${CC:-gcc} CXX=${CXX:-g++} cmake -S "$root/services/runtime-cpp" -B "$work/runtime" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DTELAR_RUNTIME_DISTRIBUTABLE=ON -DBUILD_TESTING=OFF -DGHOSTTY_VT_ROOT="$ghostty"
cmake --build "$work/runtime" --target distributable-linkage
cmake --install "$work/runtime" --prefix "$work/$name"

# An explicit target keeps crt-static off the build scripts and proc macros.
host=$(rustc -vV | sed -n 's/^host: //p')
RUSTFLAGS="-C target-feature=+crt-static" cargo build --release --locked --target "$host" \
    --manifest-path "$root/tools/diagram-renderer/Cargo.toml" --target-dir "$work/renderer"
install -m 755 "$work/renderer/$host/release/telar-diagram-renderer" "$work/$name/bin/telar-diagram-renderer"
"$root/packaging/release/check-linkage.sh" linux-headless "$work/$name/bin/telar-diagram-renderer"
"$work/$name/bin/telar" --version

tar -czf "$out/$name.tar.gz" -C "$work" "$name"
