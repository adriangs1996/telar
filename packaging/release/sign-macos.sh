#!/bin/sh
# Signs the staged Telar.app inside out. With a Developer ID Application
# identity it uses the hardened runtime and a secure timestamp, as
# notarization requires. Telar needs no hardened runtime entitlement: it runs
# no JIT, loads no library at runtime and sends no Apple Events itself
# (notifications go through /usr/bin/osascript, a separate process).
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
app=$1/prefix/Telar.app

sign() {
    if [ -n "$identity" ]; then
        codesign --force --options runtime --timestamp --sign "$identity" "$1"
    else
        codesign --force --sign - "$1"
    fi
}

sign "$app/Contents/Resources/bin/telar-diagram-renderer"
sign "$app/Contents/Resources/bin/telar"
sign "$app/Contents/MacOS/Telar"
sign "$app"
codesign --verify --strict --deep --verbose=2 "$app"
