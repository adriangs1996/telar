#!/usr/bin/env python3
"""Exercise the public Screenshot and ScreenCast portals, including video data."""
import importlib.util
from pathlib import Path
import subprocess
import time

spec = importlib.util.spec_from_file_location("protocols", Path(__file__).with_name("desktop-protocols.py"))
protocols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocols)


def main():
    p = protocols
    p.ARTIFACTS.mkdir(parents=True, exist_ok=True)
    result = p.graphical(f'python3 "{p.GUEST}/portal.py" screenshot "{p.RUN}/portal-screenshot.png"')
    assert "PASS portal screenshot contains a PNG" in result
    print(result, end="", flush=True)
    p.launch(f'python3 "{p.GUEST}/portal.py" screencast "{p.RUN}/portal-frame.ppm"', "portal-screencast")
    p.smoke.wait("portal asks the user to choose an output", lambda:
                 "SELECT_OUTPUT" in p.smoke.guest(f'cat "{p.RUN}/portal-screencast.log"'))
    p.smoke.wait("screen-sharing chooser is visible", lambda:
                 p.smoke.guest("pgrep -x slurp || true").strip())
    time.sleep(.3)
    p.screenshot("portal-chooser")
    p.pointer(0, 0)
    p.pointer(100, 100, True)
    p.pointer(100, 100, False)
    motion = 0
    def frame_received():
        nonlocal motion
        # Capture is damage driven. Generate a fresh frame after the PipeWire
        # consumer connects, instead of depending on a negotiation/preroll frame.
        motion += 1
        p.pointer(100 + (motion % 2) * 20, 100)
        log = p.smoke.guest(f'cat "{p.RUN}/portal-screencast.log"')
        assert "Traceback" not in log, log
        return "PASS PipeWire delivered" in log
    p.smoke.wait("PipeWire delivers a captured video frame", frame_received)
    log = p.smoke.guest(f'cat "{p.RUN}/portal-screencast.log"')
    print(log, end="", flush=True)
    (p.ARTIFACTS / "portals.log").write_text(result + log)
    for name in ("portal-screenshot.png", "portal-frame.ppm"):
        with (p.ARTIFACTS / name).open("wb") as output:
            subprocess.run(p.vm.ssh_command("bash", "-lc", f'cat "{p.RUN}/{name}"'), stdout=output, check=True)


if __name__ == "__main__":
    main()
