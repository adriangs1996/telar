#!/usr/bin/env bash
set -euo pipefail

version=0.16.0
case $(uname -m) in
    aarch64) checksum=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
    x86_64) checksum=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
    *) echo 'Unsupported CPU architecture.' >&2; exit 1 ;;
esac

package="zig-$(uname -m)-linux-$version"
prefix="$HOME/.local/opt/$package"
mkdir -p "$HOME/.local/opt" "$HOME/.local/bin"
if [[ ! -x "$prefix/zig" ]] || [[ $("$prefix/zig" version) != "$version" ]]; then
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT
    curl --fail --location --retry 3 --output "$temporary/zig.tar.xz" \
        "https://ziglang.org/download/$version/$package.tar.xz"
    echo "$checksum  $temporary/zig.tar.xz" | sha256sum --check
    tar -xJf "$temporary/zig.tar.xz" -C "$HOME/.local/opt"
fi

ln -sfn "$prefix/zig" "$HOME/.local/bin/zig"
path_line='export PATH="$HOME/.local/bin:$PATH"'
for profile in "$HOME/.bashrc" "$HOME/.bash_profile"; do
    touch "$profile"
    grep -Fqx "$path_line" "$profile" || printf '\n%s\n' "$path_line" >> "$profile"
done
