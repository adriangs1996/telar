# Installs, removes or reports the Neovim telar provisions for its editor panes: one release,
# fetched from that release's own page and kept only when its bytes have the SHA-256 this telar
# was built with. It goes under telar's data directory, where the runtime looks for it; nothing
# of the host's own Neovim or its configuration is touched.
set -eu
action=${1:-status}
version=@TELAR_NVIM_VERSION@
data=${XDG_DATA_HOME:-${HOME:?HOME is not set}/.local/share}
target=$data/telar/nvim/$version

# What telar's own configuration needs of a host that has none of its own: git to fetch its
# plugins, and a C compiler for the parsers Neovim does not ship. The editor starts without them.
needs() {
    [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/nvim" ] && return 0
    command -v git >/dev/null 2>&1 || echo "editor: needs git, to fetch the plugins of telar's configuration"
    command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 ||
        echo "editor: needs a C compiler, to build parsers beyond the ones Neovim ships"
    return 0
}

case "$action" in
status)
    if [ -x "$target/bin/nvim" ]; then echo "editor: present at $target/bin/nvim"; else echo "editor: absent"; fi
    needs
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
    needs
    exit 0
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
trap 'rm -rf "$work"' EXIT HUP INT TERM

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

# Unpacked beside its place and then moved there, so a run cut short leaves no half of it.
rm -rf "$target.incoming" "$target"
mv "$work/unpacked/$name" "$target.incoming"
mv "$target.incoming" "$target"
echo "editor: installed at $target/bin/nvim"
needs
