#!/bin/sh
# Signs the disk image, submits it and the command line archive to Apple's
# notary service with an App Store Connect API key, waits for the verdict and
# staples the ticket to the disk image. A bare executable cannot hold a
# stapled ticket; Gatekeeper finds the one for the archive's binaries online.
#
#   MACOS_SIGNING_IDENTITY=... NOTARY_KEY_PATH=AuthKey.p8 NOTARY_KEY_ID=... \
#   NOTARY_ISSUER_ID=... packaging/release/notarize-macos.sh DMG TARBALL
set -eu

identity=${MACOS_SIGNING_IDENTITY:?set MACOS_SIGNING_IDENTITY}
key=${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}
key_id=${NOTARY_KEY_ID:?set NOTARY_KEY_ID}
issuer=${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}
dmg=$1
tarball=$2

submit() {
    result=$(xcrun notarytool submit "$1" --key "$key" --key-id "$key_id" --issuer "$issuer" --wait --timeout 30m --output-format plist)
    status=$(printf '%s' "$result" | plutil -extract status raw -o - -)
    if [ "$status" != Accepted ]; then
        id=$(printf '%s' "$result" | plutil -extract id raw -o - -)
        printf 'notarize-macos: %s was %s\n' "$1" "$status" >&2
        xcrun notarytool log "$id" --key "$key" --key-id "$key_id" --issuer "$issuer" >&2
        exit 1
    fi

    printf 'notarize-macos: %s accepted\n' "$1"
}

codesign --force --timestamp --sign "$identity" "$dmg"
submit "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

# The notary service accepts zip archives, not tarballs.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$tarball" -C "$work"
ditto -c -k --keepParent "$work"/telar-* "$work/cli.zip"
submit "$work/cli.zip"
