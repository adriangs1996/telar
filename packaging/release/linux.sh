#!/bin/sh
# Builds the Linux desktop release for the host architecture and archives it:
#
#   telar-linux-ARCH.tar.gz   the headless tools plus the native client and its Qt
#
#   packaging/release/linux.sh OUT_DIR HEADLESS_ARCHIVE    # after install-linux-deps.sh
#
# HEADLESS_ARCHIVE is linux-headless.sh's telar-linux-ARCH-headless.tar.gz, so
# both archives ship the same static runtime, CLI and helpers. The client
# builds against the managed Qt (TELAR_QT_CACHE, default .qt-cache), and
# package_linux.py copies the Qt libraries, plugins and QML modules it loads
# beside it. The rest comes from the desktop session: check-linkage fails the
# build when a library outside that set, or a glibc or libstdc++ newer than
# the floors below, sneaks in. Ubuntu 24.04's headers turn strtol into
# __isoc23_strtol, a glibc 2.38 symbol, and Qt needs GLIBCXX_3.4.32 (GCC 13).
# The shared bootstrap prepares the pinned Zig and libghostty-vt, or
# GHOSTTY_VT_ROOT can name an existing verified build.
set -eu

out=$1
headless=$2
glibc_max=2.38
glibcxx_max=3.4.32
root=$(cd "$(dirname "$0")/../.." && pwd)
arch=$(uname -m)
case $arch in
    x86_64 | aarch64) ;;
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

tar -xzf "$headless" -C "$work"
if [ ! -d "$work/$name-headless/bin" ]; then
    printf 'linux.sh: %s has no %s-headless/bin\n' "$headless" "$name" >&2
    exit 1
fi

ghostty=${GHOSTTY_VT_ROOT:-}
if [ -z "${GHOSTTY_VT_ROOT:-}" ]; then
    ghostty=$("$root/tools/cpp" vt | tail -n 1)
fi

"$root/tools/cpp" exec -- cmake -S "$root/src/gui-cpp" -B "$work/gui" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$root/.toolchain/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DGHOSTTY_VT_ROOT="$ghostty" \
    -DTELAR_GUI_QT_BUILD_DIR="${TELAR_QT_CACHE:-$root/.qt-cache}" -DTELAR_GUI_QT_JOBS="$(nproc)"
"$root/tools/cpp" exec -- cmake --build "$work/gui" --target telar-gui telar-gui-command
python3 "$root/src/gui-cpp/tools/package_linux.py" --build "$work/gui" --headless "$work/$name-headless" --output "$work/$name"

find "$work/$name/bin" "$work/$name/lib" "$work/$name/plugins" "$work/$name/qml" -type f -name 'telar-gui*' -o -type f -name '*.so*' >"$work/elf"
TELAR_GLIBC_MAX=$glibc_max TELAR_GLIBCXX_MAX=$glibcxx_max TELAR_BUNDLED_LIBRARIES="$work/$name/lib" \
    xargs "$root/packaging/release/check-linkage.sh" linux-gui <"$work/elf"
"$work/$name/bin/telar" --version
QT_QPA_PLATFORM=offscreen LD_BIND_NOW=1 "$work/$name/bin/telar-gui" --help >/dev/null

tar -czf "$out/$name.tar.gz" -C "$work" "$name"
