#!/bin/sh
# Succeeds when a bundle or executable carries a valid Developer ID
# Application signature that chains to Apple's root, as `codesign -dvv`
# reports it: leaf, intermediate and root, in that order. An ad hoc
# signature, or one whose certificate only borrows the name, fails.
#
#   packaging/release/signed-by-developer-id.sh stage/prefix/Telar.app
set -eu

codesign --verify --strict "$1" 2>/dev/null || exit 1
details=$(codesign -dvv "$1" 2>&1) || exit 1
case $details in
    *"Authority=Developer ID Application: "*"Authority=Developer ID Certification Authority"*"Authority=Apple Root CA"*) exit 0 ;;
esac

exit 1
