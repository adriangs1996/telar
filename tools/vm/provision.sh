#!/usr/bin/env bash
set -euo pipefail

# Run inside the Fedora machine as its user. Safe to rerun.
if [[ $(uname -s) != Linux || ! -f /etc/fedora-release || $EUID == 0 ]]; then
    echo 'Run this as a non-root user inside a Fedora machine.' >&2
    exit 1
fi

# What tools/cpp needs besides its pinned toolchain, and the desktop SDK the
# GUI's private Qt links against: the Fedora names of
# packaging/release/install-linux-deps.sh.
sudo dnf install -y --setopt=install_weak_deps=False \
    gcc gcc-c++ make git curl xz python3 rsync tar patch file binutils patchelf perl flex bison pkgconf \
    ncurses fontconfig fontconfig-devel dejavu-sans-mono-fonts \
    sway foot mesa-dri-drivers grim wtype wl-clipboard dbus-daemon \
    libX11-devel libXext-devel libXfixes-devel libXi-devel libXrender-devel libxcb-devel \
    xcb-util-devel xcb-util-cursor-devel xcb-util-image-devel xcb-util-keysyms-devel \
    xcb-util-renderutil-devel xcb-util-wm-devel libxkbcommon-devel libxkbcommon-x11-devel \
    wayland-devel wayland-protocols-devel mesa-libEGL-devel mesa-libGL-devel \
    vulkan-headers vulkan-loader-devel dbus-devel

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
