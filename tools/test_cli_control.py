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


def sized16(text):
    data = text.encode()
    return struct.pack("<H", len(data)) + data


def workspace_list():
    entry = struct.pack("<Q", 42) + sized16('CLI "workspace"') + sized16("/tmp/project")
    entry += struct.pack("<H", 2) + sized16("feature/cli") + bytes([1])
    return bytes([0x98]) + struct.pack("<QH", 3, 1) + entry


def workspace_snapshot(request_id, name="Renamed", tabs=b"", count=0):
    return bytes([0x88]) + struct.pack("<QBQ", request_id, 0, 42) + sized16(name) + struct.pack("<H", count) + tabs


def agent_snapshot():
    entry = struct.pack("<QQBQQHI", 7, 9, 0, 42, 8, 1, 111) + bytes(16)
    entry += sized16("") * 3 + bytes([0, 0]) + sized16("/tmp") + bytes([2])
    entry += sized16("codex") + sized16("Codex") + sized16("")
    entry += bytes([0, 1, 0]) + sized16("") + struct.pack("<IBBBQqq", 0, 3, 1, 100, 1, 1, 10)
    return bytes([0x96]) + struct.pack("<QH", 1, 1) + entry


def thread_snapshot(skills=None, recent=None, approval=None):
    text = 'Response "quoted" 🧶'.encode()
    payload = bytes([0xAB]) + struct.pack("<QQQ", 7, 9, 3)
    payload += sized16("thread-1") + sized16("turn-1") + bytes([1, 1, 1])
    item = bytes([1]) + struct.pack("<QQQBBBIBB", 1, 1, 0, 0, 2, 2, 0, 1, 1)
    item += bytes(20) + struct.pack("<IIB", 0, len(text), 1)
    payload += item + struct.pack("<I", len(text)) + text + sized16("")
    payload += bytes([0]) if approval is None else bytes([1]) + approval
    payload += skills if skills is not None else struct.pack("<QBBB", 1, 1, 0, 0)
    payload += (recent if recent is not None else bytes([1, 0, 0])) + bytes([0])
    payload += sized16("model-1") + sized16("low") + bytes([1, 1])
    payload += sized16("model-1") + sized16("Test model") + bytes([1]) + sized16("low") + sized16("low")
    return payload


def query_thread(connection):
    request = receive_frame(connection)
    if request[0] != 0x30:
        raise AssertionError("Expected a typed conversation query")
    send_frame(connection, bytes([0xA1]) + request[1:9])
    send_frame(connection, thread_snapshot())


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
            self.assertEqual(result.stderr.strip(), "telar runtime: FileNotFound")

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

    def test_metrics_skips_other_snapshots_and_preserves_units(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, bytes([0x95, 0, 0, 0]))
            send_frame(connection, bytes([0x97]) + struct.pack("<QB HBB", 7, 42, 123, 0, 0))

        result = self.run_control(["runtime", "metrics", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "revision": 7, "cpu_percent": 42,
            "memory_used_decigib": 123, "battery_percent": None,
        })

    def test_workspace_list_exposes_git_metadata_and_escapes_names(self):
        def exchange(connection):
            self.assertEqual(receive_frame(connection)[0], 0x14)
            send_frame(connection, bytes([0x95, 0, 0, 0]))
            send_frame(connection, workspace_list())

        result = self.run_control(["workspace", "list", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [{
            "workspace_id": 42, "name": 'CLI "workspace"', "path": "/tmp/project",
            "tab_count": 2, "branch": "feature/cli", "dirty": True,
        }])

    def test_workspace_get_resolves_exact_ids_and_fails_without_partial_output(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, workspace_list())

        found = self.run_control(["workspace", "get", "42", "--json"], exchange)
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(json.loads(found.stdout)["workspace_id"], 42)
        missing = self.run_control(["workspace", "get", "99", "--json"], exchange)
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(missing.stdout, "")

    def test_workspace_create_directory_does_not_require_git(self):
        with tempfile.TemporaryDirectory(prefix="telar-directory-", dir="/tmp") as directory:
            def exchange(connection):
                request = receive_frame(connection)
                self.assertEqual(request[0], 0x15)
                self.assertIn(sized16(str(Path(directory).resolve())), request)
                self.assertIn(sized16("Existing directory"), request)
                request_id, = struct.unpack_from("<Q", request, 1)
                opened = bytes([0x81]) + struct.pack("<QQBQQBBQ", request_id, 8, 0, 42, 3, 1, 0, 1)
                send_frame(connection, opened)

            result = self.run_control([
                "workspace", "create", "--directory", directory,
                "--name", "Existing directory", "--json",
            ], exchange)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {
                "workspace_id": 42, "directory": str(Path(directory).resolve()),
            })
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_workspace_rename_waits_for_its_correlated_response(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x16)
            request_id, location_kind, workspace_id = struct.unpack_from("<QBQ", request, 1)
            self.assertEqual((location_kind, workspace_id), (0, 42))
            self.assertEqual(request[18:], sized16("Renamed"))
            send_frame(connection, workspace_snapshot(request_id + 1, "Unrelated"))
            send_frame(connection, workspace_snapshot(request_id))

        result = self.run_control(["workspace", "rename", "42", "Renamed", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"workspace_id": 42, "name": "Renamed"})

    def test_tab_list_preserves_runtime_order_and_ids(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x0C)
            request_id, kind, workspace = struct.unpack_from("<QBQ", request, 1)
            self.assertEqual((kind, workspace), (0, 42))
            tabs = struct.pack("<QHH", 8, 0, 2) + sized16("Editor") + struct.pack("<H", 0)
            tabs += struct.pack("<QHH", 3, 1, 1) + sized16("Shell") + struct.pack("<H", 0)
            send_frame(connection, workspace_snapshot(request_id, tabs=tabs, count=2))

        result = self.run_control(["tab", "list", "--workspace", "42", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        tabs = json.loads(result.stdout)
        self.assertEqual([tab["tab_id"] for tab in tabs], [8, 3])
        self.assertEqual([tab["position"] for tab in tabs], [0, 1])
        self.assertEqual(tabs[0]["pane_count"], 2)

    def test_tab_get_reads_pane_generations_without_attachment(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x08)
            request_id, kind, workspace, tab = struct.unpack_from("<QBQQ", request, 1)
            self.assertEqual((kind, workspace, tab), (0, 42, 8))
            reply = bytes([0x86]) + request[1:] + struct.pack("<H", 1)
            reply += struct.pack("<QBBQ", 5, 0, 1, 9)
            send_frame(connection, reply)

        result = self.run_control(["tab", "get", "8", "--workspace", "42", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        tab = json.loads(result.stdout)
        self.assertEqual(tab["tab_id"], 8)
        self.assertEqual(tab["panes"][0]["pane_generation"], 9)
        self.assertEqual(tab["panes"][0]["kind"], "agent")

    def test_tab_rename_uses_the_runtime_confirmed_label(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x0E)
            self.assertEqual(request[26:], sized16('New "name"'))
            send_frame(connection, bytes([0x8A]) + request[1:26] + sized16('New "name"'))

        result = self.run_control(["tab", "rename", "8", 'New "name"', "--workspace", "42", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"workspace_id": 42, "tab_id": 8, "label": 'New "name"'})

    def test_tab_close_reports_workspace_retirement(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x0F)
            send_frame(connection, bytes([0x8B]) + request[1:] + bytes([1, 0]))

        result = self.run_control(["tab", "close", "8", "--workspace", "42", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "workspace_id": 42, "tab_id": 8, "closed": True, "workspace_closed": True,
        })

    def test_tab_move_sends_an_anchor_and_reports_absolute_position(self):
        def exchange(connection):
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x10)
            self.assertEqual(request[26:], struct.pack("<BBQ", 0, 1, 3))
            send_frame(connection, bytes([0x8C]) + request[1:26] + struct.pack("<H", 4))

        result = self.run_control(["tab", "move", "8", "previous", "--relative-to", "3", "--workspace", "42", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["position"], 4)

    def test_agent_interrupt_uses_the_observed_generation_and_waits_for_acceptance(self):
        def exchange(connection):
            self.assertEqual(receive_frame(connection)[0], 0x1C)
            send_frame(connection, agent_snapshot())
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x2E)
            request_id, pane, generation = struct.unpack_from("<QQQ", request, 1)
            self.assertEqual((pane, generation), (7, 9))
            send_frame(connection, bytes([0xA1]) + struct.pack("<Q", request_id))

        result = self.run_control(["agent", "interrupt", "7", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"pane_id": 7, "pane_generation": 9, "accepted": True})

    def test_agent_thread_returns_structured_text_and_truncation(self):
        def exchange(connection):
            self.assertEqual(receive_frame(connection)[0], 0x1C)
            send_frame(connection, agent_snapshot())
            query_thread(connection)

        result = self.run_control(["agent", "thread", "7", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        thread = json.loads(result.stdout)
        self.assertEqual(thread["thread_id"], "thread-1")
        self.assertTrue(thread["truncated"])
        self.assertEqual(thread["items"][0]["text"], 'Response "quoted" 🧶')
        self.assertEqual(thread["items"][0]["phase"], "final_answer")

    def test_agent_models_preserves_provider_efforts_and_selection(self):
        def exchange(connection):
            self.assertEqual(receive_frame(connection)[0], 0x1C)
            send_frame(connection, agent_snapshot())
            query_thread(connection)

        result = self.run_control(["agent", "models", "7", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads(result.stdout)
        self.assertEqual(catalog["selected"], {"model": "model-1", "effort": "low", "access": "workspace"})
        self.assertEqual(catalog["models"], [{"id": "model-1", "label": "Test model", "default_effort": "low", "efforts": ["low"]}])

    def test_agent_skills_preserves_catalog_metadata(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, agent_snapshot())
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x30)
            send_frame(connection, bytes([0xA1]) + request[1:9])
            skills = struct.pack("<QBBB", 4, 1, 1, 1)
            skills += sized16("review") + sized16("Code Review") + sized16('Review "changes"') + bytes([1])
            send_frame(connection, thread_snapshot(skills=skills))

        result = self.run_control(["agent", "skills", "7", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads(result.stdout)
        self.assertEqual((catalog["phase"], catalog["revision"], catalog["truncated"]), ("ready", 4, True))
        self.assertEqual(catalog["skills"], [{"name": "review", "label": "Code Review", "description": 'Review "changes"', "scope": "repo"}])

    def test_agent_conversations_exposes_stable_ids_and_resume_eligibility(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, agent_snapshot())
            request = receive_frame(connection)
            send_frame(connection, bytes([0xA1]) + request[1:9])
            recent = bytes([1, 1, 1]) + sized16("previous-thread") + sized16('Previous "work"')
            send_frame(connection, thread_snapshot(recent=recent))

        result = self.run_control(["agent", "conversations", "7", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads(result.stdout)
        self.assertEqual(catalog, {"phase": "ready", "has_more": True, "can_resume": False, "conversations": [{"id": "previous-thread", "title": 'Previous "work"'}]})

    def test_agent_approvals_exposes_exact_pending_identity(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, agent_snapshot())
            request = receive_frame(connection)
            send_frame(connection, bytes([0xA1]) + request[1:9])
            approval = struct.pack("<QB", 99, 0) + sized16('Run "build"?')
            send_frame(connection, thread_snapshot(approval=approval))

        result = self.run_control(["agent", "approvals", "7", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [{"id": 99, "kind": "command", "description": 'Run "build"?'}])

    def test_agent_approve_requires_and_sends_exact_approval_identity(self):
        def exchange(connection):
            receive_frame(connection)
            send_frame(connection, agent_snapshot())
            request = receive_frame(connection)
            self.assertEqual(request[0], 0x2F)
            self.assertEqual(struct.unpack_from("<QQQB", request, 9), (7, 9, 99, 1))
            send_frame(connection, bytes([0xA1]) + request[1:9])

        result = self.run_control(["agent", "approve", "7", "99", "--json"], exchange)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["accepted"])
        result = subprocess.run([str(BINARY), "agent", "approve", "7"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
