#!/bin/sh
# Installs telar from a GitHub release.
#
#   curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh
#   curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh -s -- --app
#   sh install.sh --version 0.3.0 --bin-dir /usr/local/bin --sudo
#
# It downloads the archive for this system, or the disk image with --app,
# checks it against the release's SHA256SUMS and installs it. The only
# downloaded code it runs is the installed `telar`, after the checksum
# matched: `--version` to report it, and `cli install` to link the app's
# executable into the bin directory.
set -eu

repository=adriangs1996/telar
releases=${TELAR_RELEASES_URL:-https://github.com/$repository/releases}
version=
bin_dir=${TELAR_BIN_DIR:-$HOME/.local/bin}
app_dir=$HOME/Applications
variant=auto
install_app=false
use_sudo=false

usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --version X.Y.Z   Install this release instead of the latest one. Remote
                    mode needs the same version on both machines.
  --bin-dir DIR     Put telar in DIR (default: ~/.local/bin, or TELAR_BIN_DIR).
  --app             macOS: install Telar.app into ~/Applications and link
                    telar in DIR to the executable inside it.
  --app-dir DIR     macOS: install Telar.app into DIR instead.
  --headless        Linux: the runtime without the native client or any
                    desktop library. For servers.
  --gui             Linux: include the native client (Wayland and Vulkan).
                    Without either flag, the native client is chosen when
                    its libraries are installed.
  --sudo            Write with sudo, for directories such as /usr/local/bin
                    or /Applications.
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
        --app)
            install_app=true
            shift
            ;;
        --app-dir)
            [ $# -ge 2 ] || fail "--app-dir needs a value"
            app_dir=$2
            install_app=true
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
        [ "$install_app" = false ] || fail "--app is for macOS; on Linux, --gui installs the native client"
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

if [ "$install_app" = true ]; then
    file=Telar-$os-$arch.dmg
else
    asset=telar-$os-$arch
    if [ "$variant" = headless ]; then
        asset=$asset-headless
    fi

    file=$asset.tar.gz
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

# Checks DIR before anything is downloaded.
prepare() {
    if [ "$use_sudo" = true ]; then
        run mkdir -p "$1"
    else
        mkdir -p "$1" 2>/dev/null || true
        [ -d "$1" ] && [ -w "$1" ] || fail "$1 is not writable; choose another directory or pass --sudo"
    fi
}

prepare "$bin_dir"
if [ "$install_app" = true ]; then
    prepare "$app_dir"
    # `telar cli install` replaces only a symlink, never a file.
    if [ -e "$bin_dir/telar" ] && [ ! -L "$bin_dir/telar" ]; then
        fail "$bin_dir/telar is a file, likely a command line install; remove it and $bin_dir/telar-diagram-renderer, then rerun"
    fi
fi

work=$(mktemp -d)
mount=
cleanup() {
    if [ -n "$mount" ]; then
        hdiutil detach -quiet "$mount" || true
    fi

    rm -rf "$work"
}
trap cleanup EXIT INT TERM

printf 'Downloading %s from %s\n' "$file" "$base"
download "$base/$file" "$work/$file"
download "$base/SHA256SUMS" "$work/SHA256SUMS"

expected=$(awk -v name="$file" '$2 == name || $2 == "*" name { print $1 }' "$work/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS lists no $file"
actual=$(sha256 "$work/$file")
[ "$actual" = "$expected" ] || fail "checksum mismatch for $file: expected $expected, got $actual"

if [ "$install_app" = true ]; then
    mount=$work/volume
    mkdir "$mount"
    hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mount" "$work/$file" || fail "could not open $file"
    [ -d "$mount/Telar.app" ] || fail "$file has no Telar.app"

    # Copy beside the target and swap, so a failed copy keeps the old app.
    run rm -rf "$app_dir/.Telar.app.new"
    run ditto "$mount/Telar.app" "$app_dir/.Telar.app.new"
    run rm -rf "$app_dir/Telar.app"
    run mv "$app_dir/.Telar.app.new" "$app_dir/Telar.app"
    hdiutil detach -quiet "$mount"
    mount=

    telar=$app_dir/Telar.app/Contents/Resources/bin/telar
    run "$telar" cli install --dir "$bin_dir" >/dev/null
    printf 'Installed %s as %s/Telar.app, linked from %s/telar\n' "$("$telar" --version)" "$app_dir" "$bin_dir"
else
    mkdir "$work/unpacked"
    tar -xzf "$work/$file" -C "$work/unpacked"
    source_dir=$work/unpacked/$asset/bin
    [ -x "$source_dir/telar" ] || fail "$file has no bin/telar"

    # Copy beside the target and rename, so a running telar keeps its file.
    for tool in telar telar-diagram-renderer; do
        if [ -f "$source_dir/$tool" ]; then
            run cp "$source_dir/$tool" "$bin_dir/.$tool.new"
            run chmod 755 "$bin_dir/.$tool.new"
            run mv -f "$bin_dir/.$tool.new" "$bin_dir/$tool"
        fi
    done

    printf 'Installed %s into %s\n' "$("$bin_dir/telar" --version)" "$bin_dir"
fi

case :$PATH: in
    *:"$bin_dir":*) ;;
    *) printf 'Add %s to PATH to run telar.\n' "$bin_dir" ;;
esac
printf 'A runtime that is already running keeps its version until telar server stop.\n'
