#!/bin/sh
# Signs the staged Telar.app with a Developer ID Application identity, inside
# out, with the hardened runtime and a secure timestamp as notarization
# requires. Telar needs no hardened runtime entitlement: it runs no JIT,
# loads no library at runtime and sends no Apple Events itself (notifications
# go through /usr/bin/osascript, a separate process).
#
#   MACOS_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
#       packaging/release/sign-macos.sh STAGE
#
# The identity must already be in a keychain on the search list; the release
# workflow imports it into a temporary one.
set -eu

identity=${MACOS_SIGNING_IDENTITY:?set MACOS_SIGNING_IDENTITY}
app=$1/prefix/Telar.app

sign() {
    codesign --force --options runtime --timestamp --sign "$identity" "$1"
}

sign "$app/Contents/Resources/bin/telar-diagram-renderer"
sign "$app/Contents/Resources/bin/telar"
sign "$app/Contents/MacOS/Telar"
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
