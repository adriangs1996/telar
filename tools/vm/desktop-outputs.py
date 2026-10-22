#!/usr/bin/env python3
"""Exercise two independent outputs in an isolated headless Linux session."""
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import time

spec = importlib.util.spec_from_file_location("protocols", Path(__file__).with_name("desktop-protocols.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def main():
    p.ARTIFACTS.mkdir(parents=True, exist_ok=True)
    run = p.smoke.guest("mktemp -d /tmp/telar-outputs.XXXXXX").strip()
    before = set(p.smoke.guest('find "/run/user/$UID" -maxdepth 1 -type s -name "wayland-*"').splitlines())
    binary = p.smoke.guest(f'cat "{p.RUN}/desktop-binary"').strip()
    runtime = p.smoke.guest(f'cat "{p.RUN}/runtime-binary"').strip()
    p.smoke.guest(f'cp "$HOME/src/telar/tools/vm/desktop-smoke/smoke.lua" {run}/smoke.lua; '
                  f'TELAR_SOCKET={run}/runtime.sock TELAR_HISTORY={run}/history.db '
                  f'{shlex.quote(runtime)} server endpoint > {run}/endpoint')
    command = (f'nohup setsid dbus-run-session env XDG_RUNTIME_DIR="/run/user/$UID" '
               f'TELAR_SESSION_SERVICES=0 TELAR_DESKTOP_CONFIG={run}/smoke.lua '
               f'TELAR_DESKTOP_STATE_DIR={run}/state WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 '
               f'WLR_RENDERER=pixman QT_QUICK_BACKEND=software '
               f'{shlex.quote(binary)} {run}/runtime.sock > {run}/session.log 2>&1 < /dev/null & echo $!')
    pid = int(p.smoke.guest(command).strip())

    def state():
        try:
            return json.loads(p.smoke.guest(f'cat {run}/desktop.json'))
        except (json.JSONDecodeError, subprocess.CalledProcessError):
            return {}

    try:
        p.smoke.wait("two headless outputs publish independent workspaces", lambda:
                     len(state().get("displays", [])) == 2 and len(state().get("spaces", [])) == 2)
        sockets = set(p.smoke.guest('find "/run/user/$UID" -maxdepth 1 -type s -name "wayland-*"').splitlines()) - before
        assert len(sockets) == 1, sockets
        display = Path(sockets.pop()).name

        def graphical(command):
            return p.smoke.guest(f'XDG_RUNTIME_DIR="/run/user/$UID" WAYLAND_DISPLAY={display} {command}')

        outputs = json.loads(graphical("wlr-randr --json"))
        name = shlex.quote(outputs[0]["name"])
        original = {space["id"] for space in state()["spaces"]}
        graphical(f"wlr-randr --output {name} --off")
        p.smoke.wait("disabling an output preserves both workspaces", lambda:
                     len(state().get("displays", [])) == 1 and
                     {space["id"] for space in state().get("spaces", [])} == original)
        remaining = state()["displays"][0]["id"]
        assert all(space["display"] == remaining for space in state()["spaces"])
        active = state()["displays"][0]
        position = f'{active["x"] + active["width"]},{active["y"]}'
        graphical(f"wlr-randr --output {name} --on --pos {position} --scale 1.25")
        p.smoke.wait("reenabling an output restores independent workspace ownership", lambda:
                     len(state().get("displays", [])) == 2 and
                     len({space["display"] for space in state().get("spaces", [])}) == 2 and
                     len([space for space in state().get("spaces", []) if space["visible"]]) == 2)
        p.ARTIFACTS.mkdir(parents=True, exist_ok=True)
        (p.ARTIFACTS / "multiple-outputs.json").write_text(json.dumps(state(), indent=2))
        graphical(f"grim {run}/outputs.png")
        with (p.ARTIFACTS / "multiple-outputs.png").open("wb") as output:
            subprocess.run(p.vm.ssh_command("cat", f"{run}/outputs.png"), stdout=output, check=True)
    finally:
        p.smoke.guest(f"kill -TERM -- -{pid} 2>/dev/null || true")
        p.smoke.guest(f'TELAR_SOCKET={run}/runtime.sock {shlex.quote(runtime)} server stop')
        (p.ARTIFACTS / "multiple-outputs.log").write_text(p.smoke.guest(f"cat {run}/session.log"))
    print(f"Guest diagnostics: {run}", flush=True)


if __name__ == "__main__":
    main()
