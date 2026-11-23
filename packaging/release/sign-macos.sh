#!/bin/sh
# Signs the staged Telar.app inside out: every library, Qt framework and
# executable it carries, then the bundle. With a Developer ID Application
# identity it uses the hardened runtime and a secure timestamp, as
# notarization requires.
#
# Without an identity it signs ad hoc, so the bundle carries a complete
# signature, sealed resources included, instead of the linker's signatures
# of its executables alone. Gatekeeper still rejects such an app when it
# arrives quarantined.
#
#   MACOS_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
#       packaging/release/sign-macos.sh STAGE
#   packaging/release/sign-macos.sh STAGE      # ad hoc
#
# A Developer ID identity must already be in a keychain on the search list;
# the release workflow imports it into a temporary one.
set -eu

identity=${MACOS_SIGNING_IDENTITY:-}
root=$(cd "$(dirname "$0")/../.." && pwd)
app=$1/Telar.app
contents=$app/Contents

sign() {
    if [ -n "$identity" ]; then
        codesign --force --options runtime --timestamp --sign "$identity" "$1"
    else
        codesign --force --sign - "$1"
    fi
}

# Libraries outside the frameworks: Qt plugins and QML modules.
find "$contents" -type f -name '*.dylib' ! -path '*.framework/*' | while read -r library; do
    sign "$library"
done

for framework in "$contents"/Frameworks/*.framework; do
    [ -d "$framework" ] && sign "$framework"
done

for executable in "$contents"/Resources/bin/* "$contents"/MacOS/*; do
    sign "$executable"
done

# The Neovim of the editor panes: its parsers as any library, then the program, which under
# the hardened runtime needs leave to run the code LuaJIT writes.
# The tree-sitter parsers telar brings the editor, which its Neovim loads as libraries.
parsers=$contents/Resources/share/telar/editor
if [ -d "$parsers" ]; then
    find "$parsers" -type f -name '*.so' | while read -r parser; do
        sign "$parser"
    done
fi

nvim=$contents/Resources/share/telar/nvim
if [ -d "$nvim" ]; then
    find "$nvim" -type f -name '*.so' | while read -r parser; do
        sign "$parser"
    done

    find "$nvim" -type f -path '*/bin/*' | while read -r program; do
        if [ -n "$identity" ]; then
            codesign --force --options runtime --timestamp --entitlements "$root/packaging/macos/nvim.entitlements" \
                --sign "$identity" "$program"
        else
            codesign --force --sign - "$program"
        fi
    done
fi

sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
