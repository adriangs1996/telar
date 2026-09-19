"""Exercise CLI contracts against an isolated framed Unix socket.

Run after building: python3 tools/test_cli_control.py
"""

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import unittest


BINARY = Path(os.environ.get("TELAR_TEST_BINARY", "zig-out/bin/telar")).resolve()


def receive_exact(connection, size):
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise EOFError("CLI closed the connection before completing a frame")
        data.extend(chunk)
    return bytes(data)


def receive_frame(connection):
    size, = struct.unpack("<I", receive_exact(connection, 4))
    if size > 16 * 1024 * 1024:
        raise ValueError("Oversized CLI frame")
    return receive_exact(connection, size)


def send_frame(connection, payload):
    connection.sendall(struct.pack("<I", len(payload)) + payload)


class ControlTests(unittest.TestCase):
    def run_control(self, arguments, exchange):
        with tempfile.TemporaryDirectory(prefix="telar-cli-", dir="/tmp") as directory:
            endpoint = str(Path(directory) / "runtime.sock")
            errors = []
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(endpoint)
                os.chmod(endpoint, 0o600)
                listener.listen(1)
                listener.settimeout(10)

                def serve():
                    try:
                        with listener.accept()[0] as connection:
                            connection.settimeout(10)
                            hello = receive_frame(connection)
                            self.assertEqual(hello[:9], b"TELARIPC\x01")
                            send_frame(connection, b"TELARIPC\x02" + hello[9:])
                            exchange(connection)
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=serve)
                worker.start()
                try:
                    result = subprocess.run(
                        [str(BINARY), *arguments, "--socket", endpoint],
                        capture_output=True, text=True, timeout=10,
                    )
                finally:
                    worker.join(timeout=12)
                self.assertFalse(worker.is_alive())
                if errors:
                    raise errors[0]
                return result

    def test_runtime_status_reads_proxy_state_without_opening_a_pane(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x14)
            self.assertEqual(len(request), 9)
            self.assertNotEqual(request[1:], bytes(8))
            send_frame(connection, bytes([0x95, 1, 1, 0]))

        result = self.run_control(["runtime", "status", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(result.stdout)
        self.assertTrue(state["running"])
        self.assertEqual(state["proxy"], {
            "active": True, "scope": "wildcard", "system_trusted": False,
        })

    def test_runtime_status_does_not_start_a_missing_runtime(self):
        with tempfile.TemporaryDirectory(prefix="telar-cli-", dir="/tmp") as directory:
            endpoint = Path(directory) / "missing.sock"
            result = subprocess.run(
                [str(BINARY), "runtime", "status", "--socket", str(endpoint)],
                capture_output=True, text=True, timeout=5,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(endpoint.exists())

    def test_runtime_watch_streams_updates_in_order(self):
        def exchange(connection):
            self.assertEqual(receive_frame(connection)[0], 0x14)
            send_frame(connection, bytes([0x95, 0, 0, 0]))
            send_frame(connection, bytes([0x98]) + struct.pack("<QH", 2, 0))

        result = self.run_control(["runtime", "watch", "--jsonl", "--count", "2"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([event["type"] for event in events], ["proxy_status", "workspace_list"])
        self.assertEqual(events[1]["data"], [])

    def test_runtime_watch_reports_shutdown_and_exits(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, bytes([0x85]))

        result = self.run_control(["runtime", "watch", "--jsonl"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"type": "runtime_stopping"})


if __name__ == "__main__":
    unittest.main()
