#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux || ! -f /etc/arch-release || $EUID == 0 ]]; then
    echo 'Run this as a non-root user inside an Arch Linux machine.' >&2
    exit 1
fi

sudo pacman -Syu --noconfirm --needed \
    base-devel clang cmake ninja git curl python rsync pkgconf luajit \
    qt6-base qt6-declarative qt6-wayland wlroots0.20 wayland wayland-protocols \
    libxkbcommon pixman libdrm mesa xorg-xwayland foot ttf-dejavu \
    grim wl-clipboard xorg-xeyes xorg-xprop dbus sqlite brotli libnghttp2

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear %%I $TERM\n' "$USER" |
    sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart getty@tty1

mkdir -p "$HOME/.local/bin"
echo 'Arch desktop dependencies installed. The console is ready for telar-desktop.'
