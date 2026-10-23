#!/usr/bin/env python3
"""Real input-method and X11 application checks against the Arch QEMU seat."""
import importlib.util
from pathlib import Path
import time

spec = importlib.util.spec_from_file_location("protocols", Path(__file__).with_name("desktop-protocols.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def check_ime():
    p.graphical("fcitx5-remote -e || true")
    time.sleep(1)
    profile = p.smoke.guest("cat ~/.config/fcitx5/profile 2>/dev/null || true")
    # Configure only this disposable VM's input-method profile and restore it.
    import shlex
    configured = """[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us

[Groups/0/Items/1]
Name=pinyin

[GroupOrder]
0=Default
"""
    pid = None
    try:
        p.smoke.guest(f"mkdir -p ~/.config/fcitx5; printf %s {shlex.quote(configured)} > ~/.config/fcitx5/profile")
        p.launch("fcitx5 --replace", "fcitx-real")
        time.sleep(3)
        p.smoke.guest(f'rm -f "{p.RUN}/ime-result"')
        pid = p.launch(f'GDK_BACKEND=wayland GTK_IM_MODULE=wayland python3 "{p.GUEST}/gtk_client.py" '
                       f'ime "{p.RUN}/ime-result"', "gtk-ime")
        p.smoke.wait("GTK input field is managed", lambda: p.window("Telar GTK ime"))
        box = p.window("Telar GTK ime")["actual"]
        x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        p.pointer(0, 0)
        p.pointer(x, y, True)
        p.pointer(x, y, False)
        time.sleep(.5)
        p.graphical("fcitx5-remote -s pinyin; fcitx5-remote -o")
        p.smoke.type_text("nihao")
        time.sleep(1)
        p.screenshot("fcitx-candidates")
        p.smoke.key("spc")
        p.smoke.wait("Fcitx commits Chinese text through text-input-v3", lambda:
                     "你好" in p.smoke.guest(f'cat "{p.RUN}/ime-result" 2>/dev/null || true'), timeout=20)
        p.screenshot("fcitx-committed")
        (p.ARTIFACTS / "ime-text.txt").write_text(p.smoke.guest(f'cat "{p.RUN}/ime-result"'))
    finally:
        if pid:
            p.stop(pid)
        p.graphical("fcitx5-remote -e || true")
        time.sleep(1)
        p.smoke.guest(f"printf %s {shlex.quote(profile)} > ~/.config/fcitx5/profile")


def check_locker():
    import secrets
    import subprocess
    user = p.vm.USER
    shadow = p.smoke.guest(f"sudo getent shadow {user}").split(":")[1]
    password = secrets.token_hex(8)
    try:
        subprocess.run(p.vm.ssh_command("sudo", "chpasswd"), input=f"{user}:{password}\n",
                       text=True, check=True, capture_output=True)
        p.smoke.key("meta_l", "l")
        p.smoke.wait("Super+L launches the session locker", lambda:
                     p.smoke.guest("pgrep -x swaylock || true").strip())
        time.sleep(1)
        p.screenshot("swaylock-pam")
        p.smoke.type_text(password + "\n")
        p.smoke.wait("PAM authentication unlocks the session", lambda:
                     not p.smoke.guest("pgrep -x swaylock || true").strip())
    finally:
        subprocess.run(p.vm.ssh_command("sudo", "chpasswd", "-e"), input=f"{user}:{shadow}\n",
                       text=True, check=True, capture_output=True)


def check_xwayland():
    pid = p.launch("xeyes -title Telar-X11-integration", "x11-integration")
    try:
        p.smoke.wait("X11 application is managed", lambda: p.window("Telar-X11-integration"))
        output = p.smoke.snapshot("desktop")["displays"][0]
        p.graphical("wmctrl -r Telar-X11-integration -b add,fullscreen")
        p.smoke.wait("X11 fullscreen covers the output", lambda:
                     p.window("Telar-X11-integration")["actual"]["width"] == output["width"] and
                     p.window("Telar-X11-integration")["actual"]["height"] == output["height"])
        p.graphical("wmctrl -r Telar-X11-integration -b remove,fullscreen")
        p.smoke.wait("X11 fullscreen restores tiling", lambda:
                     p.window("Telar-X11-integration")["actual"]["width"] < output["width"])
        p.smoke.prefix("c")
        p.smoke.wait("X11 window is hidden in its previous tab", lambda:
                     not p.window("Telar-X11-integration")["visible"])
        p.graphical("wmctrl -a Telar-X11-integration")
        p.smoke.wait("X11 activation returns to the window's tab", lambda:
                     p.window("Telar-X11-integration")["visible"])
        p.screenshot("x11-activation")
    finally:
        p.stop(pid)


def main():
    p.ARTIFACTS.mkdir(parents=True, exist_ok=True)
    check_ime()
    check_locker()
    check_xwayland()


if __name__ == "__main__":
    main()
