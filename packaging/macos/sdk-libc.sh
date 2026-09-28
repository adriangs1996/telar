#!/bin/sh
# Writes a Zig libc file for the active macOS SDK, for builds that pin the
# deployment target:
#
#   packaging/macos/sdk-libc.sh > zig-out/macos-libc.txt
#   zig build bundle -Dtarget=aarch64-macos.26.0 --libc zig-out/macos-libc.txt
set -eu

sdk=$(xcrun --sdk macosx --show-sdk-path)
printf 'include_dir=%s/usr/include\n' "$sdk"
printf 'sys_include_dir=%s/usr/include\n' "$sdk"
printf 'crt_dir=%s/usr/lib\n' "$sdk"
printf 'msvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n'
