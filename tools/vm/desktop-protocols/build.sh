#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
build_dir=${TELAR_PROTOCOL_BUILD:-"$HOME/.cache/telar-protocol-tests"}
mkdir -p "$build_dir"

protocols=$(pkg-config --variable=pkgdatadir wayland-protocols)
wlr_protocols=$(pkg-config --variable=pkgdatadir wlr-protocols)
for xml in \
    "$protocols/stable/xdg-shell/xdg-shell.xml" \
    "$protocols/staging/ext-session-lock/ext-session-lock-v1.xml" \
    "$protocols/unstable/text-input/text-input-unstable-v3.xml" \
    "$wlr_protocols/unstable/wlr-layer-shell-unstable-v1.xml" \
    "$wlr_protocols/unstable/wlr-output-power-management-unstable-v1.xml" \
    "$protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml" \
    "$protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml" \
    "$source_dir/input-method-unstable-v2.xml"; do
    name=$(basename "$xml" .xml)
    wayland-scanner client-header "$xml" "$build_dir/$name.h"
    wayland-scanner private-code "$xml" "$build_dir/$name.c"
done
cc -std=c11 -Wall -Wextra -Wno-unused-parameter -g -I"$build_dir" \
    "$source_dir/client.c" "$build_dir"/*.c $(pkg-config --cflags --libs wayland-client) \
    -o "$build_dir/client"
printf '%s\n' "$build_dir/client"
