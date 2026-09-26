#!/bin/sh
# Fails when a release executable links anything outside the base system of
# its platform. A headless Linux build must not link a single desktop library.
#
#   packaging/release/check-linkage.sh macos BIN...
#   packaging/release/check-linkage.sh linux-gui BIN...
#   packaging/release/check-linkage.sh linux-headless BIN...
#
# TELAR_MACOS_MIN, when set, is the newest macOS a binary may require. TELAR_GLIBC_MAX, when set, is the newest glibc symbol version a
# Linux binary may require.
set -eu

# glibc and the GCC runtime that the Rust helper unwinds with.
linux_base='libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libgcc_s.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1'
# What the Wayland and Vulkan client needs, all present on a desktop session.
linux_desktop='libwayland-client.so.0 libwayland-cursor.so.0 libvulkan.so.1 libxkbcommon.so.0 libfontconfig.so.1 libatk-1.0.so.0 libatk-bridge-2.0.so.0 libgio-2.0.so.0 libgobject-2.0.so.0 libglib-2.0.so.0'

fail() {
    printf 'check-linkage: %s\n' "$1" >&2
    exit 1
}

# The later of two dotted versions.
newest() {
    printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

contains() {
    for item in $2; do
        if [ "$item" = "$1" ]; then
            return 0
        fi
    done

    return 1
}

check_macos() {
    binary=$1
    otool -L "$binary" | tail -n +2 | while read -r library _; do
        case $library in
            /usr/lib/* | /System/Library/*) ;;
            *) fail "$binary links $library, outside the base system" ;;
        esac
    done

    if [ -n "${TELAR_MACOS_MIN:-}" ]; then
        minos=$(otool -l "$binary" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')
        if [ "$(newest "$minos" "$TELAR_MACOS_MIN")" != "$TELAR_MACOS_MIN" ]; then
            fail "$binary requires macOS $minos, newer than $TELAR_MACOS_MIN"
        fi
    fi

    printf '%s: system libraries and frameworks only\n' "$binary"
}

check_linux() {
    binary=$1
    allowed=$2
    needed=$(readelf -d "$binary" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
    for library in $needed; do
        if ! contains "$library" "$allowed"; then
            fail "$binary needs $library, which this build must not link"
        fi
    done

    glibc=$(readelf --version-info "$binary" | sed -n 's/.*Name: GLIBC_\([0-9.]*\).*/\1/p' | sort -t. -k1,1n -k2,2n | tail -n 1)
    if [ -n "${TELAR_GLIBC_MAX:-}" ] && [ -n "$glibc" ]; then
        if [ "$(newest "$glibc" "$TELAR_GLIBC_MAX")" != "$TELAR_GLIBC_MAX" ]; then
            fail "$binary requires glibc $glibc, newer than $TELAR_GLIBC_MAX"
        fi
    fi

    printf '%s: needs %s; glibc %s\n' "$binary" "$(echo "$needed" | tr '\n' ' ')" "${glibc:-none}"
}

[ $# -ge 2 ] || fail "usage: check-linkage.sh macos|linux-gui|linux-headless BIN..."
kind=$1
shift
for binary in "$@"; do
    [ -f "$binary" ] || fail "$binary does not exist"
    case $kind in
        macos) check_macos "$binary" ;;
        linux-gui) check_linux "$binary" "$linux_base $linux_desktop" ;;
        linux-headless) check_linux "$binary" "$linux_base" ;;
        *) fail "unknown kind $kind" ;;
    esac
done
