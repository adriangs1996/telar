#!/bin/sh
# Builds and packages the macOS release for the host architecture. Signing
# happens between the two steps, so the archive and the disk image carry the
# signed executables.
#
#   packaging/release/macos.sh build STAGE
#   packaging/release/sign-macos.sh STAGE             # Developer ID or ad hoc
#   packaging/release/macos.sh package STAGE OUT_DIR
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

build() {
    stage=$1
    mkdir -p "$stage"
    stage=$(cd "$stage" && pwd)
    "$root/packaging/macos/sdk-libc.sh" >"$stage/libc.txt"
    cd "$root"
    zig build install bundle -Doptimize=ReleaseFast -Dstrip=true -Dtarget="$arch-macos.$macos_min" --libc "$stage/libc.txt" --prefix "$stage/prefix"

    app=$stage/prefix/Telar.app/Contents
    TELAR_MACOS_MIN=$macos_min "$root/packaging/release/check-linkage.sh" macos \
        "$app/MacOS/Telar" "$app/Resources/bin/telar" "$app/Resources/bin/telar-diagram-renderer"
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
    app=$stage/prefix/Telar.app
    # The bundle holds the signed copies; the archive ships the same bytes.
    cp "$app/Contents/Resources/bin/telar" "$app/Contents/Resources/bin/telar-diagram-renderer" "$tree/bin/"
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
