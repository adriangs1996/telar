#!/bin/sh
# Installs the telar command line from a GitHub release.
#
#   curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh
#   sh install.sh --version 0.3.0 --bin-dir /usr/local/bin --sudo
#
# It downloads the archive for this system, checks it against the release's
# SHA256SUMS and copies `telar` and `telar-diagram-renderer` into the bin
# directory. The only downloaded code it runs is the installed
# `telar --version`, after the checksum matched.
set -eu

repository=adriangs1996/telar
releases=${TELAR_RELEASES_URL:-https://github.com/$repository/releases}
version=
bin_dir=${TELAR_BIN_DIR:-$HOME/.local/bin}
variant=auto
use_sudo=false

usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --version X.Y.Z   Install this release instead of the latest one. Remote
                    mode needs the same version on both machines.
  --bin-dir DIR     Install into DIR (default: ~/.local/bin, or TELAR_BIN_DIR).
  --headless        Linux: the runtime and terminal client only, with no
                    desktop libraries. For servers.
  --gui             Linux: include the native client (Wayland and Vulkan).
                    Without either flag, the native client is chosen when
                    its libraries are installed.
  --sudo            Write into DIR with sudo, for directories such as
                    /usr/local/bin.
  -h, --help        Show this help.
EOF
}

fail() {
    printf 'install.sh: %s\n' "$1" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --version)
            [ $# -ge 2 ] || fail "--version needs a value"
            version=${2#v}
            shift 2
            ;;
        --bin-dir)
            [ $# -ge 2 ] || fail "--bin-dir needs a value"
            bin_dir=$2
            shift 2
            ;;
        --headless)
            variant=headless
            shift
            ;;
        --gui)
            variant=gui
            shift
            ;;
        --sudo)
            use_sudo=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "unknown option $1 (see --help)" ;;
    esac
done

case $version in
    '') ;;
    *[!0-9.]* | .* | *. | *..*) fail "version $version is not X.Y.Z" ;;
esac

case $(uname -m) in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
    *) fail "no release for architecture $(uname -m)" ;;
esac

case $(uname -s) in
    Darwin)
        os=macos
        major=$(sw_vers -productVersion | cut -d. -f1)
        [ "$major" -ge 26 ] || fail "telar needs macOS 26 or later"
        variant=gui
        ;;
    Linux)
        os=linux
        if [ "$variant" = auto ]; then
            variant=headless
            if command -v ldconfig >/dev/null 2>&1; then
                libraries=$(ldconfig -p 2>/dev/null || true)
                case $libraries in
                    *libwayland-client.so.0*libvulkan.so.1* | *libvulkan.so.1*libwayland-client.so.0*) variant=gui ;;
                esac
            fi
        fi
        ;;
    *) fail "no release for $(uname -s)" ;;
esac

asset=telar-$os-$arch
if [ "$variant" = headless ]; then
    asset=$asset-headless
fi

if [ -n "$version" ]; then
    base=$releases/download/v$version
else
    base=$releases/latest/download
fi

download() {
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https,file' --tlsv1.2 -fsSL -o "$2" "$1" || fail "could not download $1"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only -q -O "$2" "$1" || fail "could not download $1"
    else
        fail "curl or wget is required"
    fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        fail "sha256sum or shasum is required"
    fi
}

run() {
    if [ "$use_sudo" = true ]; then
        sudo "$@"
    else
        "$@"
    fi
}

if [ "$use_sudo" = false ]; then
    mkdir -p "$bin_dir" 2>/dev/null || true
    [ -d "$bin_dir" ] && [ -w "$bin_dir" ] || fail "$bin_dir is not writable; choose --bin-dir or pass --sudo"
else
    run mkdir -p "$bin_dir"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

printf 'Downloading %s from %s\n' "$asset" "$base"
download "$base/$asset.tar.gz" "$work/$asset.tar.gz"
download "$base/SHA256SUMS" "$work/SHA256SUMS"

expected=$(awk -v name="$asset.tar.gz" '$2 == name || $2 == "*" name { print $1 }' "$work/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS lists no $asset.tar.gz"
actual=$(sha256 "$work/$asset.tar.gz")
[ "$actual" = "$expected" ] || fail "checksum mismatch for $asset.tar.gz: expected $expected, got $actual"

mkdir "$work/unpacked"
tar -xzf "$work/$asset.tar.gz" -C "$work/unpacked"
source_dir=$work/unpacked/$asset/bin
[ -x "$source_dir/telar" ] || fail "$asset.tar.gz has no bin/telar"

# Copy beside the target and rename, so a running telar keeps its file.
for tool in telar telar-diagram-renderer; do
    if [ -f "$source_dir/$tool" ]; then
        run cp "$source_dir/$tool" "$bin_dir/.$tool.new"
        run chmod 755 "$bin_dir/.$tool.new"
        run mv -f "$bin_dir/.$tool.new" "$bin_dir/$tool"
    fi
done

printf 'Installed %s into %s\n' "$("$bin_dir/telar" --version)" "$bin_dir"
case :$PATH: in
    *:"$bin_dir":*) ;;
    *) printf 'Add %s to PATH to run telar.\n' "$bin_dir" ;;
esac
printf 'A runtime that is already running keeps its version until telar server stop.\n'
