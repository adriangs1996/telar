#!/usr/bin/env python3
"""Exercise the actual C++ runtime, PCAP importer and Desktop Lua subscription."""

import argparse
import pathlib
import selectors
import struct
import subprocess
import tempfile
import time


def fixture(path):
    payload = b"a\0b"
    ethernet = b"\0" * 12 + b"\x08\x00"
    udp = struct.pack("!HHHH", 53535, 53535, 8 + len(payload), 0) + payload
    ipv4 = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0,
                       b"\x7f\0\0\x01", b"\x7f\0\0\x01")
    packet = ethernet + ipv4 + udp
    path.write_bytes(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1)
                     + struct.pack("<IIII", 123, 456, len(packet), len(packet)) + packet)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    options = parser.parse_args()
    runtime_binary = options.runtime.resolve()
    probe_binary = options.lua_probe.resolve()
    api = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode/ui/api.lua"

    with tempfile.TemporaryDirectory(prefix="telar-traffic-") as temporary:
        root = pathlib.Path(temporary).resolve()
        endpoint = root / "runtime.sock"
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={network_capture=true}}}\n")
        capture = root / "fixture.pcap"
        fixture(capture)
        with (root / "runtime.log").open("w+") as log:
            runtime = subprocess.Popen([str(runtime_binary), "--socket", str(endpoint),
                                        "--config", str(config), "--history", ":memory:",
                                        "--no-session"], stdout=log, stderr=log)
            probe = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: " + log.read())
                    time.sleep(0.01)
                probe = subprocess.Popen([str(probe_binary), str(endpoint), str(api)],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                with selectors.DefaultSelector() as selector:
                    selector.register(probe.stdout, selectors.EVENT_READ)
                    if not selector.select(10) or probe.stdout.readline().strip() != "ready":
                        probe.terminate()
                        output, errors = probe.communicate(timeout=5)
                        raise RuntimeError(f"Lua subscriber did not become ready: {output} {errors}")
                subprocess.run([str(runtime_binary), "traffic", "import", "--socket", str(endpoint),
                                "--file", str(capture)], check=True, timeout=10)
                output, errors = probe.communicate(timeout=10)
                if probe.returncode != 0 or "packet verified" not in output:
                    raise RuntimeError(f"Lua packet delivery failed: {output} {errors}")
                print("Runtime -> Desktop Lua: binary packet, BPF filter and self-cancellation verified")
            finally:
                if probe is not None and probe.poll() is None:
                    probe.terminate()
                    probe.wait(timeout=5)
                runtime.terminate()
                runtime.wait(timeout=5)
            if pathlib.Path(str(endpoint) + ".traffic").exists():
                raise RuntimeError("Traffic socket was not cleaned up")


if __name__ == "__main__":
    main()
