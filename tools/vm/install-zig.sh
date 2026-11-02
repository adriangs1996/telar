#!/usr/bin/env bash
set -euo pipefail

version=${1:-0.16.0}

package="zig-$(uname -m)-linux-$version"
prefix="$HOME/.local/opt/$package"
mkdir -p "$HOME/.local/opt" "$HOME/.local/bin"
if [[ ! -x "$prefix/zig" ]] || [[ $("$prefix/zig" version) != "$version" ]]; then
    installer="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/packaging/release/install-zig.sh"
    "$installer" "$prefix" "$version"
fi

ln -sfn "$prefix/zig" "$HOME/.local/bin/zig"
path_line='export PATH="$HOME/.local/bin:$PATH"'
for profile in "$HOME/.bashrc" "$HOME/.bash_profile"; do
    touch "$profile"
    grep -Fqx "$path_line" "$profile" || printf '\n%s\n' "$path_line" >> "$profile"
done
