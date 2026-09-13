#!/usr/bin/env python3
"""Exercise native multiplexer navigation on the isolated Wayland test VM."""

import argparse
import importlib.util
import json
from pathlib import Path
import secrets
import shlex
import subprocess
import time


spec = importlib.util.spec_from_file_location("telar_vm", Path(__file__).with_name("vm.py"))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)


def ssh(script, *arguments, input_text=None, timeout=20):
    result = subprocess.run(
        vm.ssh_command("bash", "-c", script, "telar-gui-multiplexer", *arguments),
        input=input_text, capture_output=True, text=True, timeout=timeout, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"Guest command failed ({result.returncode}):\n{result.stderr}\n{result.stdout}")
    return result.stdout


ENVIRONMENT = r'''
set -euo pipefail
state=$1
binary=$2
shift 2
case "$binary" in /*) ;; *) binary="$HOME/__SOURCE__/$binary" ;; esac
export WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="/run/user/$(id -u)"
for socket_path in "$XDG_RUNTIME_DIR"/sway-ipc*.sock; do
    if test -S "$socket_path"; then export SWAYSOCK="$socket_path"; break; fi
done
test -n "$SWAYSOCK"
export TELAR_SOCKET="$state/runtime.sock" TELAR_HISTORY="$state/history.db"
export XDG_CONFIG_HOME="$state/config-home" XDG_DATA_HOME="$state/data" XDG_CACHE_HOME="$state/cache"
export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_VALIDATE_SYNC=1
export SHELL=/bin/bash
cd "$state/base"
'''.replace("__SOURCE__", vm.GUEST_SRC)


def nodes(node):
    yield node
    for child in node.get("nodes", []) + node.get("floating_nodes", []):
        yield from nodes(child)


class Window:
    """Owns one endpoint and sends input only to its verified GUI PID."""

    def __init__(self, mode, output, binary):
        self.mode = mode
        self.output = output / mode
        self.output.mkdir(parents=True, exist_ok=True)
        self.binary = binary
        self.state = "/tmp/telar-gui-multiplexer-" + secrets.token_hex(12)
        self.prefix = "b" if mode == "default" else "s"
        self.pid = None
        self.sequence = 0
        self.created = False
        self.records = {}
        self.steps = []
        self.logs = []
        self.pointer = None

    def guest(self, script, *arguments, input_text=None, timeout=20):
        return ssh(ENVIRONMENT + script, self.state, self.binary, *arguments,
                   input_text=input_text, timeout=timeout)

    def setup(self):
        ssh('umask 077; mkdir -m 700 -- "$1"; mkdir -- "$1/base"', self.state)
        self.created = True
        custom = "" if self.mode == "default" else '''
    prefix = "ctrl+s",
    keybindings = { telar.bind({ "v" }, telar.action.split_pane({ direction = "vertical" })) },'''
        source = '''local telar = require("telar")
return telar.config({
  api_version = 2,
  theme = "vesper",
  client = {%s
    sidebar = { visible = true },
    sound = { enabled = false },
  },
  gui = {
    font = { family = "DejaVu Sans Mono", size = 16 },
    cursor = { blink = false },
    window = { padding = { x = 0, y = 0 } },
  },
})
''' % custom
        self.guest('umask 077; cat > "$state/config.lua"; "$binary" config check "$state/config.lua"',
                   input_text=source)
        self.launch()

    def launch(self, reattach=False):
        self.logs.append("reattach.log" if reattach else "gui.log")
        command = "" if reattach else " /bin/bash --noprofile --norc -i"
        self.pid = int(self.guest(
            '"$binary" gui --config "$state/config.lua"' + command
            + ' > "$state/$1" 2>&1 < /dev/null &\nprintf "%s\\n" "$!"', self.logs[-1],
        ).strip())
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if any(node.get("pid") == self.pid for node in nodes(self.tree())):
                self.sway(f"[pid={self.pid}] floating enable, border none, resize set width 1280 px height 800 px, focus")
                time.sleep(0.25)
                return
            self.guest('kill -0 "$1"', str(self.pid))
            time.sleep(0.1)
        raise RuntimeError("Native GUI did not map a Wayland window within 12 seconds")

    def tree(self):
        return json.loads(self.guest("swaymsg -r -t get_tree"))

    def sway(self, command):
        response = json.loads(self.guest('swaymsg -r "$1"', command))
        if not response or any(not item.get("success") for item in response):
            raise RuntimeError(f"Sway rejected {command!r}: {response}")
        return response

    def focus(self):
        self.sway(f"[pid={self.pid}] focus")
        if not any(node.get("pid") == self.pid and node.get("focused") for node in nodes(self.tree())):
            raise RuntimeError("Refusing input: the test GUI does not own Wayland keyboard focus")

    def type(self, text):
        self.focus()
        self.guest('wtype -d 1 -- "$1"', text)

    def key(self, key, *modifiers):
        self.focus()
        arguments = []
        for modifier in modifiers:
            arguments += ["-M", modifier]
        arguments += ["-k", key]
        for modifier in reversed(modifiers):
            arguments += ["-m", modifier]
        self.guest('wtype "$@"', *arguments)

    def action(self, key, *modifiers):
        self.focus()
        arguments = ["-M", "ctrl", "-k", self.prefix, "-m", "ctrl", "-s", "40"]
        for modifier in modifiers:
            arguments += ["-M", modifier]
        arguments += ["-k", key] if modifiers or len(key) != 1 else [key]
        for modifier in reversed(modifiers):
            arguments += ["-m", modifier]
        self.guest('wtype "$@"', *arguments)
        time.sleep(0.1)

    def prompt(self, key, text, replace=False):
        self.action(key)
        if replace:
            self.key("Home", "shift")
        self.type(text)
        self.key("Return")
        time.sleep(0.15)

    def goto(self, text):
        self.prompt("g", text)

    def mark(self, name):
        self.sequence += 1
        stem = f"{self.sequence:03}-{name}"
        destination = self.state + "/" + stem
        temporary = shlex.quote(destination + ".tmp")
        command = (
            "printf '%s %s %s %s %s\\n' \"$TELAR_PANE_ID\" \"$TELAR_PANE_GENERATION\" "
            "\"$TELAR_WORKSPACE_ID\" \"$TELAR_TAB_ID\" \"$$\" > " + temporary
            + "; stty size >> " + temporary + "; mv " + temporary + " " + shlex.quote(destination)
        )
        self.type(command)
        self.key("Return")
        result = self.guest('''
for attempt in {1..100}; do
    if test -s "$state/$1"; then cat "$state/$1"; exit 0; fi
    sleep .05
done
printf 'No shell marker: %s\\n' "$1" >&2
exit 1
''', stem)
        values = [int(value) for value in result.split()]
        if len(values) != 7 or any(value <= 0 for value in values):
            raise RuntimeError(f"Invalid shell identity/PTY size for {name}: {result!r}")
        record = dict(zip(("pane", "generation", "workspace", "tab", "pid", "rows", "cols"), values))
        self.records[name] = record
        return record

    def same_pane(self, expected, name, same_size=False):
        record = self.mark(name)
        fields = ("pane", "generation", "workspace", "tab", "pid") + (("rows", "cols") if same_size else ())
        if any(record[field] != expected[field] for field in fields):
            raise AssertionError(f"Wrong pane for {name}: expected {expected}, got {record}")
        return record

    def step(self, name):
        self.steps.append(name)
        print(f"[{self.mode}] {name}", flush=True)

    def screenshot(self, name):
        time.sleep(0.15)
        vm.screenshot(self.output / f"{name}.png")

    def detach(self):
        self.action("d")
        self.guest('''
for attempt in {1..100}; do
    if ! test -r "/proc/$1/stat" || test "$(awk '{print $3}' "/proc/$1/stat")" = Z; then exit 0; fi
    sleep .05
done
exit 1
''', str(self.pid))
        self.pid = None

    def collect(self, status, failure=None):
        if not self.created:
            return
        for filename in self.logs:
            try:
                text = self.guest('tail -c 1048576 "$state/$1"', filename)
                (self.output / filename).write_text(text)
            except RuntimeError:
                pass
        report = {"status": status, "error": failure, "state": self.state, "steps": self.steps,
                  "pointer": self.pointer, "records": self.records}
        (self.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    def cleanup(self):
        if not self.created:
            return
        if self.pid is not None:
            self.guest('''
if test -r "/proc/$1/environ" && tr '\\0' '\\n' < "/proc/$1/environ" | grep -Fx "TELAR_SOCKET=$state/runtime.sock" > /dev/null; then
    swaymsg "[pid=$1] kill" > /dev/null || true
fi
''', str(self.pid))
        self.guest('"$binary" server stop > /dev/null 2>&1 || true')


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def pointer_drag(window, start, end):
    window.focus()
    outputs = json.loads(window.guest("swaymsg -r -t get_outputs"))
    outputs = [output for output in outputs if output.get("active")]
    check(len(outputs) == 1, "The VM pointer probe requires one active output")
    bounds = outputs[0]["rect"]

    def move(point):
        events = []
        for axis, length, value in zip(("x", "y"), ("width", "height"), point):
            offset = value - bounds[axis]
            check(0 <= offset < bounds[length], "Pointer coordinate lies outside the guest output")
            events.append({"type": "abs", "data": {
                "axis": axis, "value": round(offset * 32767 / (bounds[length] - 1)),
            }})
        vm.qmp("input-send-event", events=events)

    move(start)
    time.sleep(0.1)
    vm.qmp("input-send-event", events=[{"type": "btn", "data": {"button": "left", "down": True}}])
    try:
        time.sleep(0.1)
        move(end)
        time.sleep(0.15)
    finally:
        vm.qmp("input-send-event", events=[{"type": "btn", "data": {"button": "left", "down": False}}])


def sidebar(window, first):
    window.action("s")
    hidden = window.same_pane(first, "sidebar-hidden")
    check(hidden["cols"] > first["cols"], "Hiding sidebar did not enlarge the PTY")
    window.action("s")
    window.same_pane(first, "sidebar-visible", same_size=True)
    for _ in range(3):
        window.action("Right", "alt")
    wider = window.same_pane(first, "sidebar-wider")
    check(wider["cols"] < first["cols"], "Sidebar resize binding did not update the PTY")
    for _ in range(3):
        window.action("Left", "alt")
    window.same_pane(first, "sidebar-restored", same_size=True)
    window.action("w")
    window.screenshot("02-sidebar-collapsed")
    window.action("w")

    node = next(node for node in nodes(window.tree()) if node.get("pid") == window.pid)
    rect = node["rect"]
    cell = rect["width"] // hidden["cols"]
    if not cell or rect["width"] - cell * hidden["cols"] >= cell:
        window.pointer = "skipped: Sway window does not expose an exact unpadded cell grid"
        window.step("sidebar keyboard toggle and resize")
        return
    x = rect["x"] + (hidden["cols"] - first["cols"]) * cell - max(1, cell // 2)
    y = rect["y"] + rect["height"] // 2
    pointer_drag(window, (x, y), (x + 3 * cell, y))
    dragged = window.same_pane(first, "sidebar-dragged")
    check(dragged["cols"] < first["cols"], "Native sidebar drag did not resize its workbench")
    pointer_drag(window, (x + 3 * cell, y), (x, y))
    window.same_pane(first, "sidebar-drag-restored", same_size=True)
    window.pointer = "sidebar drag passed through the QEMU virtio-tablet"
    window.step("sidebar keyboard and pointer toggle/resize")


def panes(window, first):
    window.action("%")
    second = window.mark("right-pane")
    check(second["pane"] != first["pane"] and second["tab"] == first["tab"],
          "Horizontal split did not create a pane in the active tab")
    check(second["cols"] < first["cols"], "Horizontal split did not reduce columns")
    window.action("Left")
    window.same_pane(first, "focus-left")
    window.action("Right")
    window.same_pane(second, "focus-right")
    window.action('"' if window.mode == "default" else "v")
    third = window.mark("bottom-pane")
    check(third["pane"] not in (first["pane"], second["pane"]), "Vertical split did not create a distinct pane")
    check(third["rows"] < second["rows"] and third["tab"] == first["tab"], "Vertical split has wrong geometry or tab")
    window.action("Up")
    window.same_pane(second, "focus-up")
    window.action("Down")
    window.same_pane(third, "focus-down")
    for _ in range(3):
        window.action("Up", "shift")
    resized = window.same_pane(third, "pane-resized")
    check(resized["rows"] != third["rows"], "Shift+arrow did not resize the split")
    window.action("z")
    full = window.same_pane(third, "pane-fullscreen")
    check(full["rows"] > resized["rows"] and full["cols"] > resized["cols"], "Pane fullscreen did not use the workbench")
    window.screenshot("03-pane-fullscreen")
    window.action("z")
    window.same_pane(resized, "pane-unfullscreen", same_size=True)
    window.screenshot("04-splits")
    window.step("horizontal/vertical splits, directional focus, resize and pane fullscreen")
    return second, third


def tabs_and_workspaces(window, first, third):
    window.action("c")
    fourth = window.mark("second-tab")
    check(fourth["tab"] != first["tab"] and fourth["workspace"] == first["workspace"],
          "New tab did not stay in its workspace")
    window.prompt("T", "Extra-" + window.mode, replace=True)
    window.action("1")
    window.same_pane(third, "tab-one")
    window.action("n")
    window.same_pane(fourth, "tab-next")
    window.action("p")
    window.same_pane(third, "tab-previous")
    window.action("2")
    window.same_pane(fourth, "tab-two")
    window.action(",")
    window.action("2")
    window.same_pane(third, "tab-moved-left")
    window.action("1")
    window.same_pane(fourth, "tab-moved-selection")
    window.action(".")
    window.action("1")
    window.same_pane(third, "tab-move-restored")
    window.step("tab creation, rename, positions, next/previous and reordering")

    window.prompt("N", "Lab-" + window.mode)
    fifth = window.mark("new-workspace")
    check(fifth["workspace"] != first["workspace"], "New workspace did not create independent state")
    window.prompt("W", "Lab-renamed-" + window.mode, replace=True)
    window.goto("Home-" + window.mode)
    window.same_pane(third, "workspace-home")
    window.goto("Lab-renamed-" + window.mode)
    window.same_pane(fifth, "workspace-renamed")
    window.screenshot("05-workspaces")
    window.goto("Home-" + window.mode)
    window.goto("Extra-" + window.mode)
    window.same_pane(fourth, "goto-renamed-tab")
    window.action("%")
    temporary = window.mark("temporary-pane")
    check(temporary["pane"] != fourth["pane"], "Temporary split did not create a pane")
    window.action("x")
    window.same_pane(fourth, "close-pane")
    window.action("c")
    temporary_tab = window.mark("temporary-tab")
    window.action("X")
    window.same_pane(fourth, "close-tab")
    check(temporary_tab["tab"] != fourth["tab"], "Temporary tab did not have its own identity")
    window.goto("Main-" + window.mode)
    window.same_pane(third, "goto-main-tab")
    window.step("workspace creation/rename, goto targets, pane close and tab close")
    return fourth, fifth


def reattach(window, first, second, third, fourth, fifth):
    third = window.same_pane(third, "before-bottom")
    window.action("Up")
    second = window.same_pane(second, "before-top")
    window.action("Left")
    first = window.same_pane(first, "before-left")
    window.screenshot("06-before-detach")
    window.detach()
    for record in (first, second, third, fourth, fifth):
        window.guest('kill -0 "$1"', str(record["pid"]))
    window.launch(reattach=True)
    window.goto("Home-" + window.mode)
    window.goto("Main-" + window.mode)
    window.same_pane(first, "reattach-left", same_size=True)
    window.action("Right")
    window.action("Up")
    window.same_pane(second, "reattach-top", same_size=True)
    window.action("Down")
    window.same_pane(third, "reattach-bottom", same_size=True)
    window.goto("Extra-" + window.mode)
    window.same_pane(fourth, "reattach-tab")
    window.goto("Lab-renamed-" + window.mode)
    window.same_pane(fifth, "reattach-workspace")
    window.goto("Home-" + window.mode)
    window.goto("Main-" + window.mode)
    window.screenshot("07-reattached")
    window.step("detach/reattach preserves five shell PIDs, pane generations, tabs, workspaces and split sizes")


def run(mode, arguments):
    window = Window(mode, arguments.output, arguments.binary)
    try:
        window.setup()
        first = window.mark("initial")
        window.prompt("W", "Home-" + mode, replace=True)
        window.prompt("T", "Main-" + mode, replace=True)
        window.screenshot("01-initial")
        window.step("initial prompt and configured name prompts")
        sidebar(window, first)
        second, third = panes(window, first)
        fourth, fifth = tabs_and_workspaces(window, first, third)
        reattach(window, first, second, third, fourth, fifth)
        window.guest('! grep -E "Validation Error|VUID-" "$state/gui.log" "$state/reattach.log"')
        window.step("Vulkan core and synchronization validation clean")
        window.collect("passed")
    except Exception as error:
        window.collect("failed", str(error))
        try:
            window.screenshot("failure")
        except Exception:
            pass
        raise
    finally:
        window.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=Path(".zig-out/gui-multiplexer-test"))
    parser.add_argument("--skip-build", action="store_true", help="use prepared guest binary without syncing or building")
    parser.add_argument("--binary", default="zig-out/bin/telar", help="guest executable, absolute or relative to its source directory")
    parser.add_argument("--mode", choices=("default", "configured", "both"), default="both")
    arguments = parser.parse_args()
    arguments.output = arguments.output.resolve()
    vm.require_running()
    if not arguments.skip_build:
        vm.sync()
        vm.build()
    for mode in (("default", "configured") if arguments.mode == "both" else (arguments.mode,)):
        run(mode, arguments)


if __name__ == "__main__":
    main()
