#!/bin/sh
# Fails when a release executable links anything outside the base system of
# its platform. A headless Linux build must be static: no shared library, not
# even libc, and no program interpreter.
#
#   packaging/release/check-linkage.sh macos BIN...
#   packaging/release/check-linkage.sh linux-gui BIN...
#   packaging/release/check-linkage.sh linux-headless BIN...
#
# TELAR_MACOS_MIN, when set, is the newest macOS a binary may require.
# TELAR_GLIBC_MAX and TELAR_GLIBCXX_MAX, when set, are the newest glibc and
# libstdc++ symbol versions a desktop Linux binary may require.
# TELAR_BUNDLED_LIBRARIES, when set, is the directory of the libraries the
# desktop archive ships; a desktop binary may link any of them.
set -eu

# glibc and the GCC runtime that the Rust helper unwinds with.
linux_base='libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libgcc_s.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1'
# What the Qt client's X11 and Wayland platform plugins need beyond its own
# Qt libraries, all present on a desktop session: GLVND, Wayland, X11 and
# its xcb extensions, xkbcommon, Fontconfig, D-Bus and the C++ library.
linux_desktop='libstdc++.so.6 libOpenGL.so.0 libEGL.so.1 libGLX.so.0
libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1
libxkbcommon.so.0 libxkbcommon-x11.so.0 libX11.so.6 libX11-xcb.so.1 libxcb.so.1
libxcb-cursor.so.0 libxcb-glx.so.0 libxcb-icccm.so.4 libxcb-image.so.0
libxcb-keysyms.so.1 libxcb-randr.so.0 libxcb-render.so.0 libxcb-render-util.so.0
libxcb-shape.so.0 libxcb-shm.so.0 libxcb-sync.so.1 libxcb-xfixes.so.0 libxcb-xkb.so.1
libfontconfig.so.1 libdbus-1.so.3'

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

# The newest PREFIX_X.Y.Z symbol version BINARY requires, if any.
newest_version() {
    readelf --version-info "$1" | sed -n "s/.*Name: $2_\([0-9.]*\).*/\1/p" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# Fails when BINARY requires version VERSION of LIBRARY, newer than MAX.
within() {
    if [ -n "$4" ] && [ -n "$3" ] && [ "$(newest "$3" "$4")" != "$4" ]; then
        fail "$1 requires $2 $3, newer than $4"
    fi
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

    glibc=$(newest_version "$binary" GLIBC)
    within "$binary" glibc "$glibc" "${TELAR_GLIBC_MAX:-}"
    glibcxx=$(newest_version "$binary" GLIBCXX)
    within "$binary" libstdc++ "$glibcxx" "${TELAR_GLIBCXX_MAX:-}"

    printf '%s: needs %s; glibc %s; libstdc++ %s\n' "$binary" "$(echo "$needed" | tr '\n' ' ')" "${glibc:-none}" "${glibcxx:-none}"
}

check_static() {
    binary=$1
    needed=$(readelf -d "$binary" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p')
    if [ -n "$needed" ]; then
        fail "$binary needs $(echo "$needed" | tr '\n' ' ')but must be static"
    fi

    if readelf -l "$binary" | grep -q 'program interpreter'; then
        fail "$binary asks for a program interpreter but must be static"
    fi

    printf '%s: static, no shared library\n' "$binary"
}

bundled=
if [ -n "${TELAR_BUNDLED_LIBRARIES:-}" ]; then
    bundled=$(ls "$TELAR_BUNDLED_LIBRARIES")
fi

[ $# -ge 2 ] || fail "usage: check-linkage.sh macos|linux-gui|linux-headless BIN..."
kind=$1
shift
for binary in "$@"; do
    [ -f "$binary" ] || fail "$binary does not exist"
    case $kind in
        macos) check_macos "$binary" ;;
        linux-gui) check_linux "$binary" "$linux_base $linux_desktop $bundled" ;;
        linux-headless) check_static "$binary" ;;
        *) fail "unknown kind $kind" ;;
    esac
done
