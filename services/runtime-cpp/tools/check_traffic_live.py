#!/usr/bin/env python3
"""Manually verify native loopback capture; sudo applies only to the capture helper."""

import argparse
import os
import pathlib
import socket
import struct
import subprocess
import tempfile
import time


def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise RuntimeError("Traffic data connection closed")
        result.extend(chunk)
    return result


def event(connection):
    length, _ = struct.unpack("<IQ", read_exact(connection, 12))
    if length > 262144 + 1024:
        raise RuntimeError("Invalid traffic frame length")
    body = read_exact(connection, length)
    header = struct.Struct("<BQQQIIIQQQB")
    kind, _, _, _, _, link_type, _, _, _, _, offline = header.unpack_from(body)
    offset = header.size
    name_length, = struct.unpack_from("<I", body, offset)
    offset += 4
    name = body[offset:offset + name_length].decode()
    offset += name_length
    data_length, = struct.unpack_from("<I", body, offset)
    offset += 4
    if offset + data_length != len(body):
        raise RuntimeError("Invalid traffic event payload")
    return kind, name, link_type, offline, body[offset:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    options = parser.parse_args()
    if os.geteuid() == 0:
        raise SystemExit("Run this check as your account. It elevates only the capture helper.")
    binary = options.runtime.resolve()
    subprocess.run(["sudo", "-v"], check=True)

    with tempfile.TemporaryDirectory(prefix="telar-traffic-live-") as temporary:
        root = pathlib.Path(temporary).resolve()
        endpoint = root / "runtime.sock"
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={network_capture=true}}}\n")
        with (root / "runtime.log").open("w+") as log:
            runtime = subprocess.Popen([str(binary), "--socket", str(endpoint), "--config", str(config),
                                        "--history", ":memory:", "--no-session"], stdout=log, stderr=log)
            helper = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: " + log.read())
                    time.sleep(0.01)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver, \
                        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender, \
                        socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as data:
                    receiver.bind(("127.0.0.1", 0))
                    receiver.settimeout(2)
                    port = receiver.getsockname()[1]
                    expression = f"udp port {port}".encode()
                    data.connect(str(endpoint) + ".traffic")
                    data.settimeout(10)
                    # Independent golden encoding of the traffic protocol v1 greeting.
                    data.sendall(struct.pack("<IBBI", 0x31525454, 1, 1, len(expression)) + expression)
                    if event(data)[0] != 0:
                        raise RuntimeError("Traffic subscription was not acknowledged")
                    helper = subprocess.Popen(["sudo", "-n", str(binary), "traffic", "capture",
                                               "--socket", str(endpoint)])
                    deadline = time.monotonic() + 15
                    while True:
                        kind, name, _, _, payload = event(data)
                        if kind == 4 and name in ("lo", "lo0"):
                            raise RuntimeError("Loopback capture failed: " + payload.decode(errors="replace"))
                        if kind == 2 and name in ("lo", "lo0"):
                            break
                        if helper.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError("Capture helper did not open loopback")
                    token = os.urandom(32)
                    sender.sendto(token, receiver.getsockname())
                    if receiver.recv(128) != token:
                        raise RuntimeError("Loopback datagram changed")
                    while True:
                        kind, name, link_type, offline, payload = event(data)
                        if kind == 1 and payload.endswith(token):
                            if offline or name not in ("lo", "lo0"):
                                raise RuntimeError("Native packet provenance is incorrect")
                            print(f"Native loopback capture verified: interface={name} link_type={link_type}")
                            break
                        if time.monotonic() > deadline:
                            raise RuntimeError("Native loopback packet did not arrive")
            finally:
                runtime.terminate()
                runtime.wait(timeout=5)
                if helper is not None:
                    helper.wait(timeout=10)
            if pathlib.Path(str(endpoint) + ".traffic").exists():
                raise RuntimeError("Traffic socket was not cleaned up")


if __name__ == "__main__":
    main()
