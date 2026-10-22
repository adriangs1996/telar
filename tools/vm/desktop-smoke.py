#!/usr/bin/env python3
"""Exercise the Linux Desktop on the VM's real virtual display and keyboard."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

os.environ.setdefault("TELAR_VM_DISTRO", "arch")
import vm

RUN = ".local/state/telar-desktop-smoke"
ARTIFACTS = vm.STATE / "desktop-smoke"


def guest(script, timeout=60):
    result = subprocess.run(vm.ssh_command("bash", "-lc", script), capture_output=True,
                            text=True, timeout=timeout, check=True)
    return result.stdout


def snapshot(name):
    try:
        return json.loads(guest(f'cat "$HOME/{RUN}/{name}.json"'))
    except (json.JSONDecodeError, subprocess.CalledProcessError):
        return {}


def wait(description, predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            print(f"PASS {description}", flush=True)
            return value
        time.sleep(.3)
    raise AssertionError(f"Timed out: {description}")


def key(*keys):
    vm.qmp("send-key", keys=[{"type": "qcode", "data": key} for key in keys], **{"hold-time": 100})
    time.sleep(.2)


def prefix(*keys):
    key("ctrl", "b")
    key(*keys)


def type_text(value):
    plain = {" ": "spc", "\n": "ret", "/": "slash", ".": "dot", "-": "minus",
             "=": "equal", ";": "semicolon", ",": "comma", "'": "apostrophe",
             "[": "bracket_left", "]": "bracket_right", "\\": "backslash", "`": "grave_accent"}
    shifted = dict(zip('!@#$%^&*()_+{}:"<>?|~',
                       ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus",
                        "equal", "bracket_left", "bracket_right", "semicolon", "apostrophe",
                        "comma", "dot", "slash", "backslash", "grave_accent"]))
    for char in value:
        code = shifted.get(char, plain.get(char, char.lower()))
        codes = (["shift"] if char in shifted or char.isupper() else []) + [code]
        vm.qmp("send-key", keys=[{"type": "qcode", "data": item} for item in codes],
               **{"hold-time": 20})
        time.sleep(.05)


def elements(state=None):
    state = state or snapshot("workbench")
    return [element for workspace in state.get("workspaces", [])
            for tab in workspace.get("tabs", []) for element in tab.get("elements", [])]


def visible():
    return [element for workspace in snapshot("workbench").get("workspaces", [])
            if workspace.get("visible") for tab in workspace.get("tabs", [])
            for element in tab.get("elements", []) if element.get("visible")]


def screenshot(name):
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    vm.qmp("screendump", filename=str(ARTIFACTS / f"{name}.png"), format="png")
    for kind in ("desktop", "runtime", "workbench"):
        (ARTIFACTS / f"{name}-{kind}.json").write_text(json.dumps(snapshot(kind), indent=2))


def graphical(command):
    display, xdisplay, desktop = guest(f'cat "$HOME/{RUN}/environment"').splitlines()
    assert display.startswith("wayland-") and xdisplay.startswith(":") and desktop == "Telar"
    return guest(f'export XDG_RUNTIME_DIR="/run/user/$UID" '
                 f'WAYLAND_DISPLAY={shlex.quote(display)} DISPLAY={shlex.quote(xdisplay)}; {command}')


def focused(identifier):
    return any(tab.get("focused") == identifier for workspace in snapshot("workbench")["workspaces"]
               if workspace["visible"] for tab in workspace["tabs"] if tab["id"] == workspace["active_tab"])


def click(element):
    display = snapshot("desktop")["displays"][0]
    x = round((element["actual"]["x"] + 20) * 32767 / display["width"])
    y = round((element["actual"]["y"] + 50) * 32767 / display["height"])
    # The virtual tablet retains its last position between compositor restarts.
    # Force a motion event before clicking even when the target has not moved.
    vm.qmp("input-send-event", events=[{"type": "abs", "data": {"axis": "x", "value": 0}},
                                       {"type": "abs", "data": {"axis": "y", "value": 0}}])
    time.sleep(.1)
    vm.qmp("input-send-event", events=[{"type": "abs", "data": {"axis": "x", "value": x}},
                                       {"type": "abs", "data": {"axis": "y", "value": y}},
                                       {"type": "btn", "data": {"button": "left", "down": True}}])
    time.sleep(.1)
    vm.qmp("input-send-event", events=[{"type": "btn", "data": {"button": "left", "down": False}}])


def main():
    vm.require_running()
    wait("compositor and workspace connected", lambda: snapshot("desktop").get("available") and
         any(item.get("kind") == "terminal" and not item.get("error") for item in visible()))
    type_text(f"printf terminal-input-ok > ~/{RUN}/input\n")
    wait("keyboard reaches the runtime PTY", lambda:
         guest(f'cat "$HOME/{RUN}/input" 2>/dev/null || true') == "terminal-input-ok")
    type_text('printf "%s\\n" "$WAYLAND_DISPLAY" "$DISPLAY" "$XDG_CURRENT_DESKTOP" '
              f'> ~/{RUN}/environment\n')
    wait("new shells discover the compositor", lambda:
         guest(f'cat "$HOME/{RUN}/environment" 2>/dev/null || true').endswith("Telar\n"))
    screenshot("01-terminal")
    prefix("shift", "5")
    wait("prefix shortcut splits the terminal", lambda: len([item for item in visible() if item["kind"] == "terminal"]) == 2)
    screenshot("02-split")
    prefix("c")
    wait("new tab hides the previous panes", lambda: len(visible()) == 1 and len(elements()) >= 3)
    prefix("p")
    wait("switching back restores both panes", lambda: len(visible()) == 2)
    prefix("shift", "n")
    wait("workspace receives a second Space", lambda: len(snapshot("desktop").get("spaces", [])) == 2)
    wait("new workspace is presented", lambda: len(visible()) == 1)
    key("ctrl", "left")
    wait("global shortcut restores the first workspace", lambda: len(visible()) == 2)
    screenshot("03-spaces")
    wait("reported geometry matches compositor placement", lambda:
         all(item["actual"] == item["requested"] for item in visible()))

    command = f'IFS= read -r line; printf "%s" "$line" > "$HOME/{RUN}/wayland-input"; exec sleep 300'
    graphical('nohup foot --app-id=telar-smoke --title="Wayland smoke" sh -c '
              f'{shlex.quote(command)} > "$HOME/{RUN}/foot.log" 2>&1 </dev/null &')
    wait("Wayland application joins the tiling layout", lambda:
         any(item["kind"] == "external" for item in visible()))
    type_text("wayland-input-ok\n")
    wait("external Wayland application receives focus and keyboard", lambda:
         guest(f'cat "$HOME/{RUN}/wayland-input" 2>/dev/null || true') == "wayland-input-ok")
    screenshot("04-wayland")
    terminal = next(item for item in visible() if item["kind"] == "terminal")
    external = next(item for item in visible() if item["kind"] == "external")
    click(terminal)
    wait("pointer focuses a Telar pane", lambda: focused(terminal["id"]))
    click(external)
    wait("pointer focus updates the external workbench element", lambda: focused(external["id"]))
    key("ctrl", "right")
    wait("global shortcut works while an external application is focused", lambda:
         not any(item["kind"] == "external" for item in visible()))
    key("ctrl", "left")
    wait("returning restores the external application", lambda:
         any(item["kind"] == "external" for item in visible()))
    prefix("x")
    wait("closing a Wayland window removes its workbench element", lambda:
         not any(item["kind"] == "external" for item in elements()))

    graphical(f'nohup xeyes -title "XWayland smoke" > "$HOME/{RUN}/xeyes.log" 2>&1 </dev/null &')
    wait("XWayland application joins the tiling layout", lambda:
         any(item["kind"] == "external" for item in visible()))
    screenshot("05-xwayland")
    prefix("x")
    wait("closing an X11 window removes its workbench element", lambda:
         not any(item["kind"] == "external" for item in elements()))

    graphical("printf clipboard-smoke | wl-copy >/dev/null 2>&1")
    type_text("printf '")
    key("ctrl", "v")
    type_text(f"' > ~/{RUN}/clipboard-input\n")
    wait("Wayland clipboard pastes into the terminal", lambda:
         guest(f'cat "$HOME/{RUN}/clipboard-input" 2>/dev/null || true') == "clipboard-smoke")

    pane = next(item for item in visible() if item["kind"] == "terminal")
    click(pane)
    wait("pointer selects the terminal under the cursor", lambda: focused(pane["id"]))
    type_text(f"printf pointer-input-ok > ~/{RUN}/pointer-input\n")
    wait("clicked terminal receives keyboard input", lambda:
         guest(f'cat "$HOME/{RUN}/pointer-input" 2>/dev/null || true') == "pointer-input-ok")
    screenshot("06-complete")
    errors = [item for item in elements() if item.get("error")]
    assert not errors, errors

    type_text(f"sleep 300 & echo $! > ~/{RUN}/survivor\n")
    survivor = wait("runtime starts a persistent process", lambda:
                    guest(f'cat "$HOME/{RUN}/survivor" 2>/dev/null || true').strip())
    assert survivor.isdigit()
    guest("sudo systemctl stop telar-desktop-smoke")
    guest(f"kill -0 {survivor}")
    guest(f'TELAR_SOCKET="$HOME/{RUN}/runtime.sock" "$(cat "$HOME/{RUN}/runtime-binary")" runtime status')
    assert "Desktop session exiting with 0" in guest(f'cat "$HOME/{RUN}/desktop-state/logs/latest.log"')
    print("PASS compositor shuts down cleanly while runtime and child process survive", flush=True)
    print(f"Artifacts: {ARTIFACTS}", flush=True)


if __name__ == "__main__":
    main()
