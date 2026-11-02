#!/bin/sh
# Installs the Zig release this repository builds with into DIR, checking the
# tarball against the SHA-256 published in https://ziglang.org/download/index.json.
#
#   packaging/release/install-zig.sh "$RUNNER_TEMP/zig" && export PATH="$RUNNER_TEMP/zig:$PATH"
set -eu

zig_version=${2:-0.16.0}
dir=$1

case "$zig_version/$(uname -s)-$(uname -m)" in
    0.16.0/Darwin-arm64)
        platform=aarch64-macos
        sum=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
        ;;
    0.16.0/Darwin-x86_64)
        platform=x86_64-macos
        sum=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
        ;;
    0.16.0/Linux-x86_64)
        platform=x86_64-linux
        sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
        ;;
    0.16.0/Linux-aarch64)
        platform=aarch64-linux
        sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
        ;;
    0.17.0/Darwin-arm64)
        platform=aarch64-macos
        sum=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a
        ;;
    0.17.0/Darwin-x86_64)
        platform=x86_64-macos
        sum=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6
        ;;
    0.17.0/Linux-x86_64)
        platform=x86_64-linux
        sum=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
        ;;
    0.17.0/Linux-aarch64)
        platform=aarch64-linux
        sum=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
        ;;
    *)
        printf 'install-zig.sh: no Zig pinned for %s-%s\n' "$(uname -s)" "$(uname -m)" >&2
        exit 1
        ;;
esac

archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$archive" "https://ziglang.org/download/$zig_version/zig-$platform-$zig_version.tar.xz"
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | cut -d' ' -f1)
else
    actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
fi

if [ "$actual" != "$sum" ]; then
    printf 'install-zig.sh: checksum mismatch: expected %s, got %s\n' "$sum" "$actual" >&2
    exit 1
fi

mkdir -p "$dir"
tar -xJf "$archive" -C "$dir" --strip-components=1
"$dir/zig" version

# Zig 0.16.0 stages a fetched .zip, such as SQLite's amalgamation, in the
# global cache's tmp directory without creating it, so on a fresh machine
# the first build fails with "failed to create temporary zip file".
cache=${ZIG_GLOBAL_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/zig}
mkdir -p "$cache/tmp"
