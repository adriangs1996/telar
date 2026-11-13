"""Exercise an owned temporary utun through the already-running capture service."""

import json
import pathlib
import selectors
import socket
import struct
import subprocess
import sys
import time


def line(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(10): raise RuntimeError("Interface probe did not reply")
    value = process.stdout.readline()
    if not value: raise RuntimeError("Interface probe disconnected")
    return value.strip()


def interface_changes(options, endpoint, root, helper):
    from check_traffic_live import event
    desktop = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode"
    probe = None
    with (root / "interface-fixture.stderr").open("w") as errors, \
            subprocess.Popen(["sudo", "-n", str(options.interface_probe.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True) as fixture, \
            socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as data:
        greeting = json.loads(line(fixture))
        if greeting.get("ready") is not True: raise RuntimeError("Interface fixture did not start")
        token = bytes.fromhex(greeting["token"])
        if len(token) != 32 or token[-1] != 0: raise RuntimeError("Invalid binary interface fixture token")
        data.connect(str(endpoint) + ".traffic")
        data.settimeout(10)
        expression = b"udp port 53535"
        data.sendall(struct.pack("<IBBI", 0x31525454, 1, 1, len(expression)) + expression)
        if event(data)[0] != 0: raise RuntimeError("Interface capture subscription was not acknowledged")

        def command(action):
            fixture.stdin.write(action + "\n")
            fixture.stdin.flush()
            return json.loads(line(fixture))

        def observed(kind, name):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and helper.poll() is None:
                received, interface, link_type, offline, payload = event(data)
                if received == 4 and interface == name and kind != 3:
                    raise RuntimeError("Private interface capture failed: " + payload.decode(errors="replace"))
                if received == kind and interface == name:
                    if offline: raise RuntimeError("Live interface event was marked offline")
                    if kind != 1 or payload.endswith(token): return link_type
            raise RuntimeError(f"Interface lifecycle event {kind} did not arrive for {name}")

        try:
            if options.lua_probe:
                script = root / "interface-check.lua"
                script.write_text("local expected_token=string.char(" + ",".join(map(str, token)) + ")\n" + (desktop / "tests/traffic_interfaces.lua").read_text())
                probe = subprocess.Popen([str(options.lua_probe.resolve()), str(endpoint), str(desktop / "ui/api.lua"), str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if line(probe) != "ready": raise RuntimeError("Interface Lua subscription did not register")
            for _ in range(2):
                identity = command("open")
                name, index = identity["interface"], identity["index"]
                if not name.startswith("utun") or socket.if_nametoindex(name) != index: raise RuntimeError("Private interface identity does not match the OS")
                observed(2, name)
                if command("packet") != {"sent": True}: raise RuntimeError("Interface packet was not injected")
                observed(1, name)
                if command("close") != {"closed": True}: raise RuntimeError("Private interface did not close")
                observed(3, name)
            if probe:
                output, errors = probe.communicate(timeout=10)
                (root / "interface-probe.stdout").write_text(output)
                (root / "interface-probe.stderr").write_text(errors)
                if probe.returncode != 0 or "packet verified" not in output: raise RuntimeError(f"Interface Desktop Lua check failed: {output} {errors}")
            fixture.stdin.write("quit\n")
            fixture.stdin.flush()
            fixture.stdin.close()
            if fixture.wait(timeout=5) != 0: raise RuntimeError("Interface fixture failed during shutdown")
            print("Native interface creation, binary capture, removal and recreation verified" + (" through Desktop Lua with interface identity and cancellation" if probe else ""), flush=True)
        finally:
            failed = sys.exc_info()[0] is not None
            try:
                if probe is not None:
                    if probe.poll() is None: probe.terminate()
                    output, errors = probe.communicate(timeout=5)
                    if output: (root / "interface-probe.stdout").write_text(output)
                    if errors: (root / "interface-probe.stderr").write_text(errors)
            except (OSError, subprocess.TimeoutExpired) as error:
                if not failed: raise
                (root / "interface-cleanup-errors.log").write_text(str(error) + "\n")
                print(f"Interface Lua probe cleanup failed: {error}", file=sys.stderr)
