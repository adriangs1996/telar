#!/bin/sh
# Fills the tap's formula and cask with a release's version and checksums.
#
#   packaging/homebrew/render.sh VERSION SHA256SUMS TAP_DIR [--cask]
#
# Writes TAP_DIR/Formula/telar.rb, and TAP_DIR/Casks/telar-app.rb with
# --cask. The release workflow passes --cask only for notarized disk images:
# Homebrew quarantines cask downloads, and Gatekeeper blocks an app without
# a notarization ticket.
set -eu

version=$1
sums=$2
tap=$3
cask=${4:-}
here=$(cd "$(dirname "$0")" && pwd)

sum() {
    value=$(awk -v name="$1" '$2 == name || $2 == "*" name { print $1 }' "$sums")
    if [ -z "$value" ]; then
        printf 'render.sh: %s lists no %s\n' "$sums" "$1" >&2
        exit 1
    fi

    printf '%s' "$value"
}

mkdir -p "$tap/Formula"
sed -e "s/@VERSION@/$version/" \
    -e "s/@SHA256_MACOS_AARCH64@/$(sum telar-macos-aarch64.tar.gz)/" \
    -e "s/@SHA256_MACOS_X86_64@/$(sum telar-macos-x86_64.tar.gz)/" \
    -e "s/@SHA256_LINUX_AARCH64_HEADLESS@/$(sum telar-linux-aarch64-headless.tar.gz)/" \
    -e "s/@SHA256_LINUX_X86_64_HEADLESS@/$(sum telar-linux-x86_64-headless.tar.gz)/" \
    "$here/telar.rb.in" >"$tap/Formula/telar.rb"

if [ "$cask" = --cask ]; then
    mkdir -p "$tap/Casks"
    sed -e "s/@VERSION@/$version/" \
        -e "s/@SHA256_DMG_AARCH64@/$(sum Telar-macos-aarch64.dmg)/" \
        -e "s/@SHA256_DMG_X86_64@/$(sum Telar-macos-x86_64.dmg)/" \
        "$here/telar-app.rb.in" >"$tap/Casks/telar-app.rb"
fi
