#!/bin/sh
# Installs the Zig release this repository builds with into DIR, checking the
# tarball against the SHA-256 published in https://ziglang.org/download/index.json.
#
#   packaging/release/install-zig.sh "$RUNNER_TEMP/zig" && export PATH="$RUNNER_TEMP/zig:$PATH"
set -eu

zig_version=0.16.0
dir=$1

case $(uname -s)-$(uname -m) in
    Darwin-arm64)
        platform=aarch64-macos
        sum=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
        ;;
    Darwin-x86_64)
        platform=x86_64-macos
        sum=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
        ;;
    Linux-x86_64)
        platform=x86_64-linux
        sum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
        ;;
    Linux-aarch64)
        platform=aarch64-linux
        sum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
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
