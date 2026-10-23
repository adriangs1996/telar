#!/usr/bin/env python3
"""Run a test client in the active Telar VM session, including its D-Bus bus."""
import os
from pathlib import Path
import subprocess
import sys

session = {}
for line in subprocess.check_output(["systemctl", "--user", "show-environment"], text=True).splitlines():
    key, _, value = line.partition("=")
    if key in {"WAYLAND_DISPLAY", "DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE"}:
        session[key] = value
for process in Path("/proc").glob("[0-9]*"):
    try:
        if not process.joinpath("comm").read_text().startswith("telar-desktop"):
            continue
        raw = subprocess.check_output(["sudo", "cat", str(process / "environ")])
        values = dict(item.split(b"=", 1) for item in raw.split(b"\0") if b"=" in item)
        if b"TELAR_DESKTOP_STATE_DIR" not in values:
            continue
        session["DBUS_SESSION_BUS_ADDRESS"] = values[b"DBUS_SESSION_BUS_ADDRESS"].decode()
        break
    except (OSError, KeyError):
        continue
assert session.get("WAYLAND_DISPLAY") and session.get("DBUS_SESSION_BUS_ADDRESS"), session.keys()
session["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
os.environ.update(session)
os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
