# Installs, removes or reports the Neovim telar provisions for its editor panes: one release,
# fetched from that release's own page and kept only when its bytes have the SHA-256 this telar
# was built with. It goes under telar's data directory, where the runtime looks for it; nothing
# of the host's own Neovim or its configuration is touched.
set -eu
action=${1:-status}
version=@TELAR_NVIM_VERSION@
data=${XDG_DATA_HOME:-${HOME:?HOME is not set}/.local/share}
target=$data/telar/nvim/$version
# The Neovim this telar's own package brought, when the second word names where the package
# keeps it and this host runs it: the runtime starts that one, so there is nothing to fetch.
shipped=${2:+$2/$version}

ships() {
    [ -n "$shipped" ] && [ "$shipped" != "$target" ] && [ -x "$shipped/bin/nvim" ] && "$shipped/bin/nvim" --version >/dev/null 2>&1
}

case "$action" in
status)
    if [ -x "$target/bin/nvim" ]; then
        echo "editor: present at $target/bin/nvim"
    elif ships; then
        echo "editor: shipped with this telar at $shipped/bin/nvim"
    else
        echo "editor: absent"
    fi

    exit 0
    ;;
uninstall)
    if [ -d "$target" ]; then rm -rf "$target"; echo "editor: removed $target"; else echo "editor: absent"; fi
    exit 0
    ;;
install) ;;
*)
    echo "telar integration: unknown action $action" >&2
    exit 1
    ;;
esac

if [ -x "$target/bin/nvim" ]; then
    echo "editor: already present at $target/bin/nvim"
    exit 0
fi

if ships; then
    echo "editor: shipped with this telar at $shipped/bin/nvim"
    exit 0
fi

# The releases of Neovim for Linux are built for glibc: on a musl host they do not run.
# TELAR_NVIM_ANY_LIBC is for who builds a package on such a host for the others.
if [ -z "${TELAR_NVIM_ANY_LIBC:-}" ] && { [ -f /etc/alpine-release ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; }; then
    echo "telar integration: telar has no Neovim for a musl host; install Neovim $version or later there" >&2
    exit 1
fi

case "$(uname -s)-$(uname -m)" in
Linux-x86_64)
    name=nvim-linux-x86_64
    sum=@TELAR_NVIM_SHA256_LINUX_X86_64@
    ;;
Linux-aarch64 | Linux-arm64)
    name=nvim-linux-arm64
    sum=@TELAR_NVIM_SHA256_LINUX_ARM64@
    ;;
Darwin-arm64)
    name=nvim-macos-arm64
    sum=@TELAR_NVIM_SHA256_MACOS_ARM64@
    ;;
Darwin-x86_64)
    name=nvim-macos-x86_64
    sum=@TELAR_NVIM_SHA256_MACOS_X86_64@
    ;;
*)
    echo "telar integration: telar has no Neovim for $(uname -s) $(uname -m); install Neovim $version or later there" >&2
    exit 1
    ;;
esac

command -v tar >/dev/null 2>&1 || {
    echo "telar integration: tar is needed to unpack Neovim" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/telar-nvim.XXXXXX")
lock=$target.lock
held=
incoming=
trap 'rm -rf "$work" ${incoming:+"$incoming"}; [ -z "$held" ] || rmdir "$lock" 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM

# An archive already on the host, for one without a network: it must be the same bytes.
archive=${TELAR_NVIM_ARCHIVE:-}
if [ -z "$archive" ]; then
    command -v curl >/dev/null 2>&1 || {
        echo "telar integration: curl is needed to fetch Neovim" >&2
        exit 1
    }
    archive=$work/$name.tar.gz
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$archive" "https://github.com/neovim/neovim/releases/download/v$version/$name.tar.gz" || {
        echo "telar integration: Neovim $version could not be fetched" >&2
        exit 1
    }
fi

if command -v sha256sum >/dev/null 2>&1; then
    found=$(sha256sum "$archive" | cut -d ' ' -f 1)
elif command -v shasum >/dev/null 2>&1; then
    found=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
else
    echo "telar integration: sha256sum or shasum is needed to check Neovim" >&2
    exit 1
fi

if [ "$found" != "$sum" ]; then
    echo "telar integration: the Neovim archive is not the one this telar expects; nothing was installed" >&2
    exit 1
fi

mkdir -p "$work/unpacked" "$data/telar/nvim"
tar -xzf "$archive" -C "$work/unpacked"
if [ ! -x "$work/unpacked/$name/bin/nvim" ]; then
    echo "telar integration: the Neovim archive holds no nvim" >&2
    exit 1
fi

# One install at a time puts the version in place; another that ran beside it finds it there.
# The lock is held only to move it, so one older than a minute was left by an install that
# was killed.
waited=0
until mkdir "$lock" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 60 ]; then
        echo "telar integration: $lock is held; remove it if no install of the editor is running" >&2
        exit 1
    fi
    sleep 1
done
held=1

if [ -x "$target/bin/nvim" ]; then
    echo "editor: already present at $target/bin/nvim"
    exit 0
fi

# Unpacked beside its place and then moved there, so a run cut short leaves no half of it.
incoming=$(mktemp -d "$target.incoming.XXXXXX")
mv "$work/unpacked/$name" "$incoming/$name"
rm -rf "$target"
mv "$incoming/$name" "$target"
rmdir "$incoming"
echo "editor: installed at $target/bin/nvim"
