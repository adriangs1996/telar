#!/usr/bin/env python3
"""Protocol, lock-failure, output and GTK DnD checks against the Arch QEMU seat."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

os.environ.setdefault("TELAR_VM_DISTRO", "arch")
import vm

spec = importlib.util.spec_from_file_location("smoke", Path(__file__).with_name("desktop-smoke.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
ARTIFACTS = vm.STATE / "desktop-protocols"
GUEST = "$HOME/src/telar/tools/vm/desktop-protocols"
RUN = "$HOME/.local/state/telar-desktop-smoke"


def graphical(command, timeout=60):
    return smoke.guest(f'python3 "{GUEST}/environment.py" bash -lc {shlex.quote(command)}', timeout)


def launch(command, name):
    return int(graphical(f'nohup env {command} > "{RUN}/{name}.log" 2>&1 < /dev/null & echo $!').strip())


def stop(pid):
    smoke.guest(f"kill {int(pid)} 2>/dev/null || true")


def window(title):
    state = smoke.snapshot("workbench")
    return next((element for element in smoke.elements(state) if element.get("title") == title), None)


def pointer(x, y, down=None):
    display = smoke.snapshot("desktop")["displays"][0]
    events = [{"type": "abs", "data": {"axis": "x", "value": round(x * 32767 / display["width"])}},
              {"type": "abs", "data": {"axis": "y", "value": round(y * 32767 / display["height"])}}]
    if down is not None:
        events.append({"type": "btn", "data": {"button": "left", "down": down}})
    vm.qmp("input-send-event", events=events)


def screenshot(name):
    vm.qmp("screendump", filename=str(ARTIFACTS / f"{name}.png"), format="png")


def check_pointer():
    pid = launch('"$HOME/.cache/telar-protocol-tests/client" pointer 12000', "pointer")
    try:
        smoke.wait("pointer client is managed", lambda: window("Telar protocol probe"))
        box = window("Telar protocol probe")["actual"]
        x, y = box["x"] + box["width"] / 2, box["y"] + box["height"] / 2
        pointer(0, 0)
        pointer(x, y, True)
        pointer(x, y, False)
        smoke.wait("client locks the pointer", lambda:
                   "POINTER_LOCKED" in smoke.guest(f'cat "{RUN}/pointer.log"'))
        vm.qmp("input-send-event", events=[
            {"type": "rel", "data": {"axis": "x", "value": 30}},
            {"type": "rel", "data": {"axis": "y", "value": 20}},
        ])
        pointer(x + 40, y + 40)
        smoke.wait("relative motion arrives while pointer coordinates stay locked", lambda:
                   "PASS POINTER_LOCK" in smoke.guest(f'cat "{RUN}/pointer.log"'))
        (ARTIFACTS / "pointer.log").write_text(smoke.guest(f'cat "{RUN}/pointer.log"'))
    finally:
        stop(pid)


def check_drag():
    # The base smoke test leaves a nested split. Give both GTK fixtures enough
    # space for their minimum sizes so one cannot cover the other's drag target.
    smoke.prefix("c")
    smoke.wait("drag fixtures have an isolated tab", lambda:
               len(smoke.visible()) == 1 and smoke.visible()[0]["kind"] == "terminal")
    smoke.guest(f'rm -f "{RUN}/drag-result"')
    source = launch(f'python3 "{GUEST}/gtk_client.py" source "{RUN}/drag-source"', "drag-source")
    destination = launch(f'python3 "{GUEST}/gtk_client.py" destination "{RUN}/drag-result"', "drag-destination")
    try:
        smoke.wait("GTK source is managed", lambda: window("Telar GTK source"))
        smoke.wait("GTK destination is managed", lambda: window("Telar GTK destination"))
        time.sleep(1)
        src, dst = window("Telar GTK source")["actual"], window("Telar GTK destination")["actual"]
        screenshot("drag-before")
        (ARTIFACTS / "drag-geometry.json").write_text(json.dumps({"source": src, "destination": dst}))
        x1, y1 = src["x"] + src["width"] / 2, src["y"] + src["height"] / 2
        x2, y2 = dst["x"] + dst["width"] / 2, dst["y"] + dst["height"] / 2
        pointer(0, 0)
        pointer(x1, y1)
        time.sleep(.3)
        pointer(x1, y1, True)
        for step in range(1, 21):
            pointer(x1 + (x2 - x1) * step / 20, y1 + (y2 - y1) * step / 20)
            time.sleep(.1)
        pointer(x2, y2, False)
        smoke.wait("drag-and-drop transfers a file URI between GTK clients", lambda:
                   smoke.guest(f'cat "{RUN}/drag-result" 2>/dev/null || true') == "file:///tmp/telar-drag-test.txt")
        screenshot("drag-and-drop")
    finally:
        stop(source)
        stop(destination)


def main():
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    smoke.guest(f'bash "{GUEST}/build.sh"')
    graphical("fcitx5-remote -e || true")
    time.sleep(.5)
    for mode in ("ime", "fullscreen", "maximize", "layer", "power", "lock"):
        result = graphical(f'"$HOME/.cache/telar-protocol-tests/client" {mode} 4000')
        (ARTIFACTS / f"{mode}.log").write_text(result)
        assert "PASS " in result, result
        print(f"PASS {mode} protocol roundtrip", flush=True)

    # Kill a locker after its locked acknowledgement. No old desktop pixels or
    # global shortcut must become available until a replacement explicitly unlocks.
    pid = launch('"$HOME/.cache/telar-protocol-tests/client" lock 60000', "lock-crash")
    smoke.wait("lock acknowledged after presentation", lambda:
               "LOCKED" in smoke.guest(f'cat "{RUN}/lock-crash.log"'))
    before = smoke.snapshot("runtime")
    smoke.guest(f"kill -KILL {pid}")
    time.sleep(.5)
    smoke.prefix("c")
    smoke.type_text("echo lock-leak\n")
    after = smoke.snapshot("runtime")
    assert before["tabs"] == after["tabs"], "A global shortcut escaped the session lock"
    result = graphical('"$HOME/.cache/telar-protocol-tests/client" power 2000')
    assert "PASS OUTPUT_POWER" in result
    screenshot("locker-crash")
    from PIL import Image
    frame = Image.open(ARTIFACTS / "locker-crash.png").convert("RGB")
    colors = frame.getcolors(frame.width * frame.height)
    assert sum(count for count, color in colors if color == (0, 0, 0)) / (frame.width * frame.height) > .99
    result = graphical('"$HOME/.cache/telar-protocol-tests/client" lock 2000')
    assert "PASS LOCK_UNLOCK" in result
    print("PASS locker crash stays black and blocks shortcuts; replacement unlocks", flush=True)

    base = smoke.snapshot("desktop")["displays"][0]
    outputs = graphical("wlr-randr --json")
    (ARTIFACTS / "outputs.json").write_text(outputs)
    name = json.loads(outputs)[0]["name"]
    graphical(f"wlr-randr --output {shlex.quote(name)} --scale 1.25")
    smoke.wait("fractional output scale updates desktop geometry", lambda:
               smoke.snapshot("desktop")["displays"][0]["width"] == round(base["width"] / 1.25))
    screenshot("fractional-scale")
    graphical(f"wlr-randr --output {shlex.quote(name)} --scale 1 --transform 90")
    smoke.wait("output rotation updates desktop geometry", lambda:
               smoke.snapshot("desktop")["displays"][0]["width"] == base["height"])
    graphical(f"wlr-randr --output {shlex.quote(name)} --transform normal")
    smoke.wait("output configuration restores original geometry", lambda:
               smoke.snapshot("desktop")["displays"][0]["width"] == base["width"])

    check_drag()
    check_pointer()
    print(f"Artifacts: {ARTIFACTS}", flush=True)


if __name__ == "__main__":
    main()
