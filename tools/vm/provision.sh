#!/usr/bin/env bash
set -euo pipefail

# Run inside the Fedora machine as its user. Safe to rerun.
if [[ $(uname -s) != Linux || ! -f /etc/fedora-release || $EUID == 0 ]]; then
    echo 'Run this as a non-root user inside a Fedora machine.' >&2
    exit 1
fi

sudo dnf install -y --setopt=install_weak_deps=False \
    gcc gcc-c++ make git curl xz python3 rsync tar \
    sqlite-devel libnghttp2-devel brotli-devel pkgconf just ncurses fontconfig fontconfig-devel dejavu-sans-mono-fonts \
    sway foot mesa-dri-drivers mesa-vulkan-drivers vulkan-loader vulkan-tools \
    wayland-devel wayland-protocols-devel libxkbcommon-devel grim wtype wl-clipboard \
    vulkan-headers vulkan-loader-devel vulkan-validation-layers glslc \
    atk-devel at-spi2-core-devel at-spi2-atk-devel python3-pyatspi dbus-daemon gobject-introspection

# The desktop: the console logs this user in and its shell starts sway, so
# the desktop is on the QEMU display when there is one and on the virtual
# framebuffer when there is not. The virtio GPU has no 3D acceleration, so
# wlroots draws with pixman.
autologin=/etc/systemd/system/getty@tty1.service.d/autologin.conf
wanted="[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER --noclear %I \$TERM"
if [[ ! -f $autologin || $(<"$autologin") != "$wanted" ]]; then
    sudo mkdir -p "$(dirname "$autologin")"
    printf '%s\n' "$wanted" | sudo tee "$autologin" > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart getty@tty1
fi
mkdir -p "$HOME/.config/sway"
cat > "$HOME/.config/sway/config" <<'SWAY'
include /etc/sway/config
output * resolution 1600x1000
exec foot
SWAY
sway_line='[[ -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 ]] && exec env WLR_RENDERER=pixman sway'
grep -Fqx "$sway_line" "$HOME/.bash_profile" || printf '\n%s\n' "$sway_line" >> "$HOME/.bash_profile"

"$HOME/.local/bin/zig" version
