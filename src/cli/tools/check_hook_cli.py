#!/usr/bin/env python3
from concurrent.futures import ThreadPoolExecutor
import json
import os
import socket
import struct
import subprocess
import time


def receive_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            if not result:
                return None
            raise RuntimeError("Truncated hook frame")
        result.extend(chunk)
    return bytes(result)


def receive_frame(connection):
    prefix = receive_exact(connection, 4)
    return None if prefix is None else receive_exact(connection, struct.unpack("<I", prefix)[0])


def send_frame(connection, frame):
    connection.sendall(struct.pack("<I", len(frame)) + frame)


def capture(listener, stopped, refusal):
    frames = []
    listener.settimeout(0.02)
    while not stopped.is_set():
        try:
            connection, _ = listener.accept()
            break
        except TimeoutError:
            pass
    else:
        return frames

    with connection:
        connection.settimeout(5)
        hello = receive_frame(connection)
        if hello is None or hello[:9] != b"TELARIPC\x01":
            raise RuntimeError("Invalid hook handshake")
        send_frame(connection, b"TELARIPC\x02" + hello[9:])
        while (frame := receive_frame(connection)) is not None:
            frames.append(frame.hex())
            if frame[0] == 0x43:
                continue
            if frame[0] == refusal:
                send_frame(connection, b"\x84" + frame[1:9] + struct.pack("<H", 1) + b"fixture refusal")
            elif frame[0] == 0x3c:
                send_frame(connection, b"\xb4" + frame[1:9] + struct.pack("<Q", 73) + b"\x01")
            else:
                send_frame(connection, b"\xa1" + frame[1:9])
    return frames


def run_case(binary, root, case):
    import threading
    path = root / "runtime.sock"
    path.unlink(missing_ok=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment.update({"HOME": str(root), "CODEX_HOME": str(root / "codex"),
                        "XDG_CONFIG_HOME": str(root / "config"), "CURSOR_CONFIG_DIR": str(root / "cursor"),
                        "TELAR_PANE_ID": "17", "TELAR_PANE_GENERATION": "29"})
    for key, value in case.get("environment", {}).items():
        if value is None:
            environment.pop(key, None)
        else:
            environment[key] = value
    payload = case["input"]
    data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
    stopped = threading.Event()
    with socket.socket(socket.AF_UNIX) as listener, ThreadPoolExecutor(max_workers=1) as executor:
        listener.bind(str(path))
        listener.listen()
        future = executor.submit(capture, listener, stopped, case.get("refusal"))
        started = time.perf_counter_ns()
        try:
            result = subprocess.run([str(binary), "hook", case["provider"], "--socket", str(path)],
                                    input=data, env=environment, capture_output=True, timeout=15)
        finally:
            stopped.set()
        elapsed = time.perf_counter_ns() - started
        frames = future.result()
    return {"status": result.returncode, "stdout": result.stdout.hex(), "stderr": result.stderr.hex(), "frames": frames}, elapsed
