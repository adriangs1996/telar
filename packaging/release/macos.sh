#!/bin/sh
# Builds and packages the macOS release for the host architecture. Signing
# happens between the two steps, so the archive and the disk image carry the
# signed executables.
#
#   packaging/release/macos.sh build STAGE
#   packaging/release/sign-macos.sh STAGE             # Developer ID or ad hoc
#   packaging/release/macos.sh package STAGE OUT_DIR
#
# `build` needs Homebrew's cmake, ninja, llvm, openssl@3, libnghttp2, brotli,
# zstd and libpng, Zig 0.17 for libghostty-vt and Cargo for the diagram renderer.
# The managed Qt builds into TELAR_QT_CACHE (default STAGE/qt-cache) once.
#
# `package` writes telar-macos-ARCH.tar.gz, with the command line tools and
# their notices, and Telar-macos-ARCH.dmg.
set -eu

# Metal 4, which the native client requires, first shipped in macOS 26.
macos_min=26.0
root=$(cd "$(dirname "$0")/../.." && pwd)
arch=$(uname -m)
if [ "$arch" = arm64 ]; then
    arch=aarch64
fi

# The executables the archive ships, beside each other in bin/.
tools="telar telar-runtime telar-config-check telar-diagram-renderer"

build() {
    stage=$1
    mkdir -p "$stage"
    stage=$(cd "$stage" && pwd)
    llvm=$(brew --prefix llvm)
    compilers="-DCMAKE_C_COMPILER=$llvm/bin/clang -DCMAKE_CXX_COMPILER=$llvm/bin/clang++ -DCMAKE_OSX_DEPLOYMENT_TARGET=$macos_min"

    # GHOSTTY_VT_ROOT names an existing build of the pinned libghostty-vt;
    # otherwise it builds here with Zig 0.17 (ZIG, default zig).
    ghostty=${GHOSTTY_VT_ROOT:-$stage/ghostty}
    if [ -z "${GHOSTTY_VT_ROOT:-}" ]; then
        python3 "$root/services/runtime-cpp/tools/build_ghostty.py" --zig "${ZIG:-zig}" --build-dir "$stage/ghostty-build" --prefix "$ghostty"
    fi

    # TELAR_RUNTIME_DISTRIBUTABLE links the non-system libraries statically
    # and fails the build when any executable links outside the base system.
    # shellcheck disable=SC2086
    cmake -S "$root/services/runtime-cpp" -B "$stage/runtime" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DTELAR_RUNTIME_DISTRIBUTABLE=ON -DBUILD_TESTING=OFF $compilers \
        -DGHOSTTY_VT_ROOT="$ghostty" \
        -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" -DNGHTTP2_ROOT="$(brew --prefix libnghttp2)" \
        -DBROTLI_ROOT="$(brew --prefix brotli)" -DZSTD_ROOT="$(brew --prefix zstd)" -DPNG_ROOT="$(brew --prefix libpng)"
    cmake --build "$stage/runtime" --target distributable-linkage
    cmake --install "$stage/runtime" --prefix "$stage/prefix"

    cargo build --release --locked --manifest-path "$root/tools/diagram-renderer/Cargo.toml" --target-dir "$stage/renderer"
    install -m 755 "$stage/renderer/release/telar-diagram-renderer" "$stage/prefix/bin/telar-diagram-renderer"

    # shellcheck disable=SC2086
    cmake -S "$root/services/gui-cpp" -B "$stage/gui" -G Ninja -DCMAKE_BUILD_TYPE=Release $compilers \
        -DGHOSTTY_VT_ROOT="$ghostty" -DTELAR_GUI_QT_BUILD_DIR="${TELAR_QT_CACHE:-$stage/qt-cache}"
    cmake --build "$stage/gui" --target telar-gui telar-gui-command

    rm -rf "$stage/Telar.app"
    python3 "$root/services/gui-cpp/tools/package_macos.py" --release \
        --build "$stage/gui" --runtime-prefix "$stage/prefix" --output "$stage/Telar.app"

    app=$stage/Telar.app/Contents
    for tool in $tools; do
        TELAR_MACOS_MIN=$macos_min "$root/packaging/release/check-linkage.sh" macos "$app/Resources/bin/$tool"
    done
    plutil -lint "$app/Info.plist"
    "$app/Resources/bin/telar" --version
}

package() {
    stage=$(cd "$1" && pwd)
    out=$2
    mkdir -p "$out"
    out=$(cd "$out" && pwd)

    name=telar-macos-$arch
    tree=$stage/$name
    rm -rf "$tree"
    mkdir -p "$tree/bin" "$tree/share/telar"
    app=$stage/Telar.app
    # The bundle holds the signed copies; the archive ships the same bytes.
    for tool in $tools; do
        cp "$app/Contents/Resources/bin/$tool" "$tree/bin/"
    done
    cp -R "$app/Contents/Resources/licenses" "$tree/share/telar/licenses"
    # Leave out Finder metadata and extended attributes such as provenance.
    tar --no-xattrs --no-mac-metadata -czf "$out/$name.tar.gz" -C "$stage" "$name"

    volume=$stage/dmg
    rm -rf "$volume"
    mkdir -p "$volume"
    cp -R "$app" "$volume/"
    ln -s /Applications "$volume/Applications"
    hdiutil create -volname Telar -srcfolder "$volume" -ov -format UDZO "$out/Telar-macos-$arch.dmg"
}

command=${1:-}
[ $# -gt 0 ] && shift
case $command in
    build) build "$@" ;;
    package) package "$@" ;;
    *)
        printf 'usage: macos.sh build STAGE | package STAGE OUT_DIR\n' >&2
        exit 1
        ;;
esac
