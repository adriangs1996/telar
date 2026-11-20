#!/usr/bin/env python3
"""Exercise CLI contracts with private files and, optionally, a real runtime.

Every subprocess gets a private HOME/XDG/TMPDIR and no inherited TELAR_*.
Project/repository have no --socket option: their environment explicitly names
the same private socket. run_suite is also the stack-to-stack comparison driver.
"""

import argparse
import contextlib
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import socket
import struct
import subprocess
import sys
import tempfile
import time


class Fixture:
    def __init__(self, binary, root):
        self.binary = Path(binary).resolve()
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("TELAR_", "GIT_"))}
        self.env.pop("SSH_AUTH_SOCK", None)
        for key, name in (("HOME", "home"), ("XDG_RUNTIME_DIR", "run"), ("XDG_DATA_HOME", "data"),
                          ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp")):
            directory = self.root / name
            directory.mkdir(exist_ok=True, mode=0o700)
            self.env[key] = str(directory)
        self.socket = self.root / "s"
        self.results = {}

    def invoke(self, name, *args, data=b"", code=0, cwd=None, socket=False, timeout=20):
        argv = [str(self.binary), *map(str, args)]
        if socket:
            argv += ["--socket", str(self.socket)]
        result = subprocess.run(argv, env=self.env, input=data, capture_output=True, cwd=cwd or self.root, timeout=timeout)
        if code is not None:
            assert result.returncode == code, (name, argv, result.returncode, result.stdout, result.stderr)
        self.results[name] = (result.returncode, result.stdout, result.stderr)
        return result

    def git(self, root, *args):
        environment = dict(self.env, GIT_AUTHOR_DATE="2025-01-01T00:00:00Z", GIT_COMMITTER_DATE="2025-01-01T00:00:00Z")
        return subprocess.check_output(["git", "-C", str(root), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", *map(str, args)], env=environment, stderr=subprocess.PIPE)

    @contextlib.contextmanager
    def runtime(self):
        self.env["TELAR_SOCKET"] = str(self.socket)
        with (self.root / "server.log").open("wb") as log:
            process = subprocess.Popen([str(self.binary), "server", "--socket", str(self.socket), "--no-config"],
                                       env=self.env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not self.socket.exists():
                    assert process.poll() is None, (self.root / "server.log").read_bytes()
                    assert time.monotonic() < deadline, "private runtime did not listen"
                    time.sleep(.02)
                yield
            finally:
                if process.poll() is None:
                    self.invoke("server-stop", "server", "stop", socket=True)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                self.env.pop("TELAR_SOCKET", None)


def fixture_query(f, name, arguments, frames, code=0, hold=False, timeout=20):
    """Answers the runtime state request with `frames`; with `hold`, keeps the connection
    open after them until the client leaves, as a runtime that sends nothing more."""
    def receive(connection):
        def exact(length):
            data = bytearray()
            while len(data) < length:
                part = connection.recv(length - len(data))
                assert part
                data.extend(part)
            return bytes(data)
        return exact(struct.unpack("<I", exact(4))[0])

    def serve(listener):
        connection, _ = listener.accept()
        with connection:
            connection.settimeout(5)
            hello = receive(connection)
            assert hello[:9] == b"TELARIPC\x01"
            accept = b"TELARIPC\x02" + hello[9:]
            connection.sendall(struct.pack("<I", len(accept)) + accept)
            request = receive(connection)
            assert request[0] == 0x14 and request[-1] == 0
            for frame in frames:
                connection.sendall(struct.pack("<I", len(frame)) + frame)
            if hold:
                connection.settimeout(timeout)
                while connection.recv(4096):
                    pass

    f.socket.unlink(missing_ok=True)
    try:
        with socket.socket(socket.AF_UNIX) as listener, ThreadPoolExecutor(max_workers=1) as worker:
            listener.bind(str(f.socket))
            listener.listen()
            listener.settimeout(5)
            future = worker.submit(serve, listener)
            result = f.invoke(name, *arguments, socket=True, code=code, timeout=timeout)
            future.result()
            return result
    finally:
        f.socket.unlink(missing_ok=True)


def fixed_runtime_outputs(f):
    metrics = struct.pack("<BQBHBBHH", 0x97, 11, 37, 125, 1, 81, 12, 320)
    no_battery = struct.pack("<BQBHBBHH", 0x97, 11, 37, 125, 0, 0, 12, 320)
    proxy = bytes([0x95, 1, 1, 0, 1]) + struct.pack("<H", 4242) + bytes([1]) + struct.pack("<H", 1111)
    workspace = bytes([0x98]) + struct.pack("<QHH", 12, 0, 0)
    agents = bytes([0x96]) + struct.pack("<QH", 13, 0)
    expected = {"revision": 11, "cpu_percent": 37, "memory_used_decigib": 125, "memory_total_decigib": 320, "cpu_count": 12, "battery_percent": 81}
    result = fixture_query(f, "fixture/metrics-json", ["runtime", "metrics", "--json"], [metrics])
    assert json.loads(result.stdout) == expected, result.stdout
    fixture_query(f, "fixture/metrics-text", ["runtime", "metrics"], [metrics])
    # A machine without a battery reports none, not an empty one.
    result = fixture_query(f, "fixture/metrics-no-battery-json", ["runtime", "metrics", "--json"], [no_battery])
    assert json.loads(result.stdout) == expected | {"battery_percent": None}, result.stdout
    fixture_query(f, "fixture/metrics-no-battery-text", ["runtime", "metrics"], [no_battery])
    fixture_query(f, "fixture/status-port", ["runtime", "status"], [proxy])
    status = json.loads(fixture_query(f, "fixture/status-port-json", ["runtime", "status", "--json"], [proxy]).stdout)
    assert status["running"] and status["proxy"]["scope"] == "wildcard", status
    assert (status["proxy"]["port"], status["proxy"]["preferred_port"]) == (4242, 1111), status
    status = json.loads(fixture_query(f, "fixture/status-no-port-json", ["runtime", "status", "--json"], [bytes([0x95, 1, 1, 0, 0, 0])]).stdout)
    assert (status["proxy"]["port"], status["proxy"]["preferred_port"]) == (None, None), status
    events = fixture_query(f, "fixture/watch", ["runtime", "watch", "--count", "4"], [proxy, metrics, workspace, agents]).stdout.splitlines()
    sample = next(event["data"] for event in map(json.loads, events) if event["type"] == "system_metrics")
    assert sample["has_battery"] is True and sample["battery_percent"] == 81, sample
    events = fixture_query(f, "fixture/proxy-filter", ["proxy", "watch", "--count", "1"], [metrics, workspace, agents, proxy]).stdout.splitlines()
    assert [json.loads(event)["type"] for event in events] == ["proxy_status"], events
    # A refusal or a stopping runtime ends a query at once, not at its reply timeout.
    refused = bytes([0x84]) + struct.pack("<QH", 1, 2) + b"refused"
    fixture_query(f, "fixture/status-refused", ["runtime", "status"], [refused], code=1, hold=True)
    fixture_query(f, "fixture/status-stopping", ["runtime", "status"], [metrics, bytes([0x85])], code=1, hold=True)
    fixture_query(f, "fixture/metrics-stopping", ["runtime", "metrics"], [proxy, bytes([0x85])], code=1, hold=True)
    # A runtime that never answers is a timeout, exit 3, which scripts tell from an error.
    fixture_query(f, "fixture/status-timeout", ["runtime", "status"], [], code=3, hold=True, timeout=45)
    fixture_query(f, "fixture/proxy-stop", ["proxy", "watch"], [metrics, proxy, bytes([0x85])])
    resync = bytes([0x93]) + struct.pack("<BQBB", 0, 7, 0, 0)
    fixture_query(f, "fixture/resync", ["runtime", "watch"], [proxy, resync], code=1)

    def text(value):
        encoded = value.encode()
        return struct.pack("<H", len(encoded)) + encoded
    def workspace_entry(identity, name):
        return struct.pack("<Q", identity) + text(name) + text(str(f.root)) + struct.pack("<H", 1) + text("main") + bytes([1])

    def agent_entry(pane, title):
        entry = struct.pack("<QQBQQHI", pane, 2, 0, 7, 3, 1, 123) + bytes(range(16))
        entry += text("Workspace") + text("Tab") + text(title) + bytes([2, 2]) + text("checkout")
        entry += bytes([1]) + text("claude") + text("Claude Code") + text("") + bytes([0, 2, 2]) + text("Needs input")
        entry += struct.pack("<IBBBQqqQ", 5, 3, 1, 100, 1, 1000, 2000, 0)
        return entry + text('line\nquote"') + struct.pack("<HH", 1, 2) + text("Review")
    # Agents parse every line of the stream, whatever number of entries it lists.
    names = ['Work "one"', "line\ntwo"]
    titles = ['A "title"', "back\\slash"]
    workspace = bytes([0x98]) + struct.pack("<QH", 12, 2) + workspace_entry(7, names[0]) + workspace_entry(8, names[1]) + struct.pack("<H", 0)
    agents = bytes([0x96]) + struct.pack("<QH", 13, 2) + agent_entry(1, titles[0]) + agent_entry(4, titles[1])
    lines = fixture_query(f, "fixture/snapshots", ["runtime", "watch", "--count", "2"], [workspace, agents]).stdout.splitlines()
    assert len(lines) == 2, lines
    listed, snapshot = map(json.loads, lines)
    assert [(entry["workspace_id"], entry["name"]) for entry in listed["data"]] == [(7, names[0]), (8, names[1])], listed
    assert [(entry["pane_id"], entry["title"], entry["final_message"]) for entry in snapshot["data"]] == [(1, titles[0], 'line\nquote"'), (4, titles[1], 'line\nquote"')], snapshot


def offline(f):
    invalid = [
        ("exec",), ("exec", "start"), ("exec", "status"), ("exec", "status", "0"),
        ("exec", "--json", "--", "true"), ("exec", "list", "--detach"),
        ("exec", "--workspace", "0", "--", "true"), ("exec", "--timeout", "-1", "--", "true"),
        ("runtime",), ("runtime", "wat"), ("runtime", "watch", "--count", "0"),
        ("runtime", "watch", "--json", "--jsonl"), ("runtime", "metrics", "--count", "2"),
        ("proxy", "watch", "--count", "no"), ("diagnostics", "logs", "--pid", "0"),
        ("diagnostics", "logs", "--lines", "10001"), ("diagnostics", "limits", "--lines", "1"),
        ("history",), ("history", "search"), ("history", "show", "0"),
        ("history", "list", "--limit", "1001"), ("history", "list", "--cwd", "--cwd"),
        ("history", "stats", "--period", "bad"), ("history", "prune", "--before", "1969-12-31"),
        ("repository", "prepare"), ("repository", "receive", "--bytes", "-1"),
        ("project", "setup"), ("project", "setup", "--cwd", "relative"),
        ("file", "put", "relative", "--bytes", "0"), ("file", "put", "/unused"),
        ("api",), ("api", "schema", "--other"),
        ("exec", "status", "+1"), ("exec", "status", "_1"),
        ("runtime", "watch", "--count", "1__0", "--invalid"),
        ("history", "show", "+1", "--limit", "0"),
        ("history", "show", "-1"), ("history", "show", "1_0", "--limit", "0"),
    ]
    for index, args in enumerate(invalid):
        result = f.invoke(f"arguments/{index}", *args, code=1)
        assert not result.stdout and b"; see `telar " in result.stderr

    schema = f.invoke("api/json", "api", "schema", "--json")
    contract = json.loads(schema.stdout)
    assert set(contract) == {"schema_version", "fingerprint", "client_requests", "server_messages", "agent_statuses", "bounds"}
    assert contract["client_requests"]["execution_request"] > 0
    assert contract["server_messages"]["execution_reply"] > 0
    # The contract of each schema is published beside this test. A schema with no contract fails:
    # a new one is reviewed and recorded before it passes, and the one of a published schema never
    # changes.
    assert contract["fingerprint"] == contract["schema_version"].encode().hex()
    published = Path(__file__).resolve().parent / "contracts" / f"api_schema_{contract['schema_version']}.json"
    assert published.exists(), f"publish the contract of schema {contract['schema_version']} in {published}"
    assert contract == json.loads(published.read_text())
    f.invoke("api/text", "api", "schema")
    f.invoke("runtime/unavailable", "runtime", "status", "--socket", f.root / "absent", code=1)
    f.invoke("limits/unavailable", "diagnostics", "limits", "--socket", f.root / "absent", code=1)
    fixed_runtime_outputs(f)

    path = f.root / "binary"
    binary = bytes(range(256)) * 513 + b"\0\xfftail"
    result = f.invoke("file/put", "file", "put", path, "--bytes", len(binary), data=binary)
    assert result.stdout == f'{{"bytes":{len(binary)},"published":true}}\n'.encode()
    assert path.read_bytes() == binary and path.stat().st_mode & 0o777 == 0o600
    assert f.invoke("file/get", "file", "get", path).stdout == binary
    f.invoke("file/no-replace", "file", "put", path, "--bytes", "1", data=b"x", code=1)
    assert path.read_bytes() == binary
    for label, actual, expected in (("short", b"a", 2), ("long", b"abc", 2)):
        target = f.root / label
        f.invoke("file/" + label, "file", "put", target, "--bytes", expected, data=actual, code=1)
        assert not target.exists()
    assert not list(f.root.glob(".telar-file-*"))
    f.invoke("file/empty", "file", "put", f.root / "empty", "--bytes", "0")
    link = f.root / "link"
    link.symlink_to(path)
    f.invoke("file/symlink", "file", "get", link, code=1)
    hard = f.root / "hard"
    os.link(path, hard)
    f.invoke("file/hardlink", "file", "get", hard, code=1)
    hard.unlink()
    os.mkfifo(f.root / "fifo", 0o600)
    f.invoke("file/fifo", "file", "get", f.root / "fifo", code=1)
    linked_parent = f.root / "linked-parent"
    linked_parent.symlink_to(f.root, target_is_directory=True)
    f.invoke("file/parent-symlink", "file", "put", linked_parent / "no-file", "--bytes", "0", code=1)
    # Another user could swap a file published into a directory they can write.
    shared = f.root / "shared"
    for mode in (0o777, 0o775):
        shared.mkdir()
        shared.chmod(mode)
        result = f.invoke(f"file/unsafe-parent-{mode:o}", "file", "put", shared / "published", "--bytes", "1", data=b"x", code=1)
        assert b"UnsafeTransferDirectory" in result.stderr and not list(shared.iterdir()), result.stderr
        shared.rmdir()
    f.invoke("file/limit", "file", "put", f.root / "large", "--bytes", 128 * 1024 * 1024 + 1, code=1)

    for name, content in (("s.runtime-11.log", b"old\nsecond\nlast\x08\x0c\x7f\n"),
                          ("s.client-42.log", b"one\ntwo\n"), ("s.client-42.log.1", b"ignored\n"),
                          ("s.runtime.log", b"runtime\n"), ("s.runtime.start.log", b"start\n")):
        (f.root / name).write_bytes(content)
    f.invoke("logs/text", "diagnostics", "logs", "--lines", "2", socket=True)
    logs = json.loads(f.invoke("logs/json", "diagnostics", "logs", "--lines", "2", "--json", socket=True).stdout)
    assert len(logs) == 4
    assert [Path(item["path"]).name for item in logs] == sorted(Path(item["path"]).name for item in logs)
    by_pid = json.loads(f.invoke("logs/pid", "diagnostics", "logs", "--pid", "42", "--json", socket=True).stdout)
    assert [Path(item["path"]).name for item in by_pid] == ["s.client-42.log"], by_pid
    clients = f.invoke("logs/component", "diagnostics", "logs", "--component", "client", "--json", socket=True)
    assert [Path(item["path"]).name for item in json.loads(clients.stdout)] == ["s.client-42.log"], clients.stdout
    runtime_logs = json.loads(f.invoke("logs/component-runtime", "diagnostics", "logs", "--component", "runtime", "--json", socket=True).stdout)
    assert sorted(Path(item["path"]).name for item in runtime_logs) == ["s.runtime-11.log", "s.runtime.log", "s.runtime.start.log"], runtime_logs
    f.invoke("logs/missing", "diagnostics", "logs", "--pid", "999", socket=True, code=2)
    (f.root / "s.runtime.log").unlink()
    (f.root / "s.runtime.log").symlink_to(path)
    f.invoke("logs/unsafe", "diagnostics", "logs", socket=True, code=1)
    (f.root / "s.runtime.log").unlink()

    checkout = f.root / "project"
    checkout.mkdir(mode=0o700)
    f.invoke("project/absent", "project", "setup", "--cwd", checkout)
    # A coordinator reads `not_declared` and knows nothing prepared the checkout.
    result = f.invoke("project/absent-json", "project", "setup", "--cwd", checkout, "--json")
    assert json.loads(result.stdout) == {"execution_id": None, "environment": "not_declared", "ready": False}, result.stdout
    assert not [path for path in f.root.rglob("*") if path.is_socket()], "a checkout without a recipe started a runtime"
    (checkout / ".telar").mkdir(mode=0o700)
    (checkout / ".telar/setup.json").write_text('{"version":2,"argv":["true"]}')
    f.invoke("project/version", "project", "setup", "--cwd", checkout, code=1)
    recipes = ["{", "[]", "{}", '{"version":1,"argv":[],"extra":1}',
               '{"version":1,"version":1,"argv":[]}', '{"version":"1","argv":[]}',
               '{"version":1.0,"argv":[]}', '{"version":-1,"argv":[]}',
               '{"version":256,"argv":[]}', '{"version":1,"argv":[7]}',
               '{"version":1', '{"version":1,"argv":["hello"',
               '{"version":1,"argv":["hello', '{"version":1,"argv":',
               '{"version":1,"argv":tru', '{"version":1,"argv":1e',
               '{"version":1,"argv":,}', '{"version":1,,', '',
               '{"version":"0x1","argv":["true"]}']
    for index, recipe in enumerate(recipes):
        (checkout / ".telar/setup.json").write_text(recipe)
        f.invoke(f"project/invalid-{index}", "project", "setup", "--cwd", checkout, code=1)
    f.invoke("repository/invalid", "repository", "receive", "--transport", "https://example.test/p.git", "--identity", "wrong", code=1)


def execution(f):
    common = ("--socket", str(f.socket))
    data = bytes(range(256)) * 257
    program = "import sys; d=sys.stdin.buffer.read();sys.stdout.buffer.write(d);sys.stderr.buffer.write(d[::-1]);sys.exit(7)"
    result = f.invoke("exec/released", "exec", "--id", "1000", *common, "--", sys.executable, "-c", program, data=data, code=7)
    assert result.stdout == data and result.stderr == data[::-1]
    f.invoke("exec/released-status", "exec", "status", "1000", socket=True, code=125)
    # An exit equal to telar's own 125 stays retained for `exec status`.
    result = f.invoke("exec/streams", "exec", "--id", "1001", *common, "--", sys.executable, "-c", program.replace("exit(7)", "exit(125)"), data=data, code=125)
    assert result.stdout == data and result.stderr == data[::-1]
    status = json.loads(f.invoke("exec/status", "exec", "status", "1001", socket=True).stdout)
    assert status["state"] == "exited" and status["stdin_bytes"] == len(data)
    output = f.invoke("exec/output", "exec", "output", "1001", socket=True)
    assert output.stdout == data and output.stderr == data[::-1]
    output = f.invoke("exec/offset", "exec", "output", "1001", "--stdout-offset", "3", "--stderr-offset", "5", socket=True)
    assert output.stdout == data[3:] and output.stderr == data[::-1][5:]
    f.invoke("exec/missing", "exec", "status", "9999", socket=True, code=125)
    # Not the runtime's own directory nor HOME, which a lost --cwd falls back to.
    directory = f.root / "exec-cwd"
    directory.mkdir(mode=0o700)
    result = f.invoke("exec/cwd", "exec", "--id", "1006", "--no-stdin", "--cwd", directory, *common, "--", "/bin/pwd")
    assert result.stdout == f"{directory}\n".encode(), result.stdout
    f.invoke("exec/spawn-failure", "exec", "--id", "1002", "--no-stdin", *common, "--", "/no-such-telar-fixture", code=125)
    f.invoke("exec/detach", "exec", "--id", "1003", "--detach", "--json", *common, "--", sys.executable, "-c", "import time;time.sleep(20)")
    f.invoke("exec/retry", "exec", "--id", "1003", "--detach", *common, "--", sys.executable, "-c", "import time;time.sleep(20)")
    f.invoke("exec/conflict", "exec", "--id", "1003", "--detach", *common, "--", "/bin/echo", "different", code=125)
    f.invoke("exec/still-running", "exec", "forget", "1003", socket=True, code=125)
    f.invoke("exec/cancel", "exec", "cancel", "1003", socket=True)
    deadline = time.monotonic() + 4
    while True:
        result = f.invoke("exec/cancelled", "exec", "status", "1003", socket=True)
        if json.loads(result.stdout)["state"] in ("exited", "failed"):
            break
        assert time.monotonic() < deadline
        time.sleep(.02)
    f.invoke("exec/list", "exec", "list", socket=True)
    f.invoke("exec/forget", "exec", "forget", "1003", socket=True)
    f.invoke("exec/forgotten", "exec", "status", "1003", socket=True, code=125)
    f.invoke("exec/timeout", "exec", "--id", "1004", "--no-stdin", "--timeout", "1", *common, "--", sys.executable, "-c", "import time;time.sleep(20)", code=124)
    f.invoke("exec/timeout-status", "exec", "status", "1004", socket=True)
    f.invoke("exec/timeout-cancel", "exec", "cancel", "1004", socket=True)
    f.invoke("exec/retained-start", "exec", "--id", "1005", "--detach", *common, "--", sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'x'*(1024*1024+23))")
    deadline = time.monotonic() + 4
    while True:
        status = json.loads(f.invoke("exec/retained-status", "exec", "status", "1005", socket=True).stdout)
        if status["state"] == "exited":
            break
        assert time.monotonic() < deadline
        time.sleep(.02)
    f.invoke("exec/retained-lost", "exec", "output", "1005", socket=True, code=125)
    retained = f.invoke("exec/retained-resume", "exec", "output", "1005", "--stdout-offset", status["stdout_offset"], socket=True)
    assert retained.stdout == b"x" * (1024 * 1024)


def runtime_queries(f):
    f.invoke("runtime/status-json", "runtime", "status", "--json", socket=True)
    f.invoke("runtime/status-text", "runtime", "status", socket=True)
    metrics = json.loads(f.invoke("runtime/metrics-json", "runtime", "metrics", "--json", socket=True).stdout)
    assert 0 <= metrics["cpu_percent"] <= 100 and metrics["cpu_count"] > 0
    f.invoke("runtime/metrics-text", "runtime", "metrics", socket=True)
    events = f.invoke("runtime/watch", "runtime", "watch", "--jsonl", "--count", "4", socket=True)
    assert {json.loads(line)["type"] for line in events.stdout.splitlines()} == {"proxy_status", "system_metrics", "workspace_list", "agent_snapshot"}
    event = f.invoke("proxy/watch", "proxy", "watch", "--count", "1", socket=True)
    assert json.loads(event.stdout)["type"] == "proxy_status"
    limits(f, "limits/json")
    f.invoke("limits/text", "diagnostics", "limits", socket=True)


def limits(f, name):
    """`diagnostics limits --json` is JSON with the documented keys; `requested` is a count or null."""
    report = json.loads(f.invoke(name, "diagnostics", "limits", "--json", socket=True).stdout)
    assert set(report) == {"runtime_evicted", "client_evicted", "refused_reports", "limits"}, report
    for entry in report["limits"]:
        assert set(entry) == {"name", "noun", "value", "requested", "route", "origin", "hits", "last_ms"}, entry
        assert entry["requested"] is None or isinstance(entry["requested"], int), entry
    return report


def history_rows(f):
    """Rows the runtime recorded, as `history list` shows and filters them."""
    database = Path(f.env["XDG_DATA_HOME"]) / "telar/history.db"
    session = bytes(range(16))
    rows = [
        # command, workspace, exit code, status, author, provider
        ("printf exited", "/p", 3, 0, 0, None),
        ("printf running", "/p", None, 2, 0, None),
        ("printf interrupted", "/q", None, 1, 0, None),
        ("printf by-agent", "/q", 0, 0, 1, "claude"),
    ]
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO session (id,pane_id,location_kind,location_id,tab_id,workspace_path,shell,started_at_ms) VALUES (?,?,?,?,?,?,?,?)",
                           (session, 900, 0, 1, 1, "/p", "/bin/sh", 1735689600000))
        for sequence, (command, workspace, code, status, author, provider) in enumerate(rows, 1):
            connection.execute("INSERT INTO command (session_id,pane_id,location_kind,location_id,tab_id,sequence,command,cwd,workspace_path,started_at_ms,duration_ns,exit_code,status,author,provider) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                               (session, 900, 0, 1, 1, sequence, command, workspace, workspace, 1735689600000 + sequence, 0, code, status, author, provider))

    def listed(name, *args):
        lines = f.invoke(name, "history", "list", *args, socket=True).stdout.splitlines()
        return {line.rsplit(b"  ", 1)[-1].split(b" ")[-1]: line for line in lines}

    # STATUS is the exit code, RUN or INT.
    columns = {command: line.split(b"  ")[2] for command, line in listed("history/columns").items()}
    assert columns == {b"exited": b"3", b"running": b"RUN", b"interrupted": b"INT", b"by-agent": b"0"}, columns
    agent = listed("history/author-agent", "--author", "agent")
    assert list(agent) == [b"by-agent"] and b"[claude]" in agent[b"by-agent"], agent
    assert sorted(listed("history/author-human", "--author", "human")) == [b"exited", b"interrupted", b"running"]
    f.invoke("history/author-invalid", "history", "list", "--author", "x", socket=True, code=1)
    assert sorted(listed("history/workspace", "--workspace", "/p")) == [b"exited", b"running"]
    f.invoke("history/rows-prune", "history", "prune", "--yes", socket=True)


def history_imports(f):
    """`history import` without a kind reads the file by its name, or the shell's own histfile."""
    named = f.root / "detected"
    named.mkdir()
    (named / "fish_history").write_bytes(b"- cmd: printf auto-fish\n  when: 1735689700\n")
    f.invoke("history/import-auto-file", "history", "import", "--file", named / "fish_history", socket=True)
    home = Path(f.env["HOME"]) / ".zsh_history"
    home.write_bytes(b": 1735689701:0;printf auto-zsh\n")
    try:
        f.invoke("history/import-auto-home", "history", "import", socket=True)
    finally:
        home.unlink()
    crlf = f.root / "crlf_history"
    crlf.write_bytes(b"printf crlf\r\n")
    f.invoke("history/import-crlf", "history", "import", "bash", "--file", crlf, socket=True)
    listing = f.invoke("history/imported-auto", "history", "list", socket=True).stdout
    commands = sorted(line.rsplit(b"  ", 1)[-1] for line in listing.splitlines())
    assert commands == [b"printf auto-fish", b"printf auto-zsh", b"printf crlf"], listing
    f.invoke("history/imports-prune", "history", "prune", "--yes", socket=True)


def history(f):
    fixtures = {
        "zsh": b": 1735689600:0;printf first\n: 1735689601:0;printf second\\\ncontinued\nplain\x1b\tcommand\n",
        "bash": b"#1735689602\nprintf bash\n#1735689603\necho duplicate\necho duplicate\n",
        "fish": b"- cmd: printf fish\n  when: 1735689604\n- cmd: echo fish\n  when: 1735689605\n",
    }
    for kind, content in fixtures.items():
        file = f.root / (kind + "_history")
        file.write_bytes(content)
        f.invoke("history/import-" + kind, "history", "import", kind, "--file", file, socket=True)
        f.invoke("history/idempotent-" + kind, "history", "import", kind, "--file", file, socket=True)
    listing = f.invoke("history/list", "history", "list", "--limit", "100", socket=True)
    assert b"printf bash" in listing.stdout and b"printf fish" in listing.stdout and b"\\ncontinued" in listing.stdout
    f.invoke("history/search", "history", "search", "printf", socket=True)
    f.invoke("history/cwd", "history", "list", "--cwd", socket=True)
    f.invoke("history/pane", "history", "list", "--pane", "1", socket=True)
    f.invoke("history/failed", "history", "list", "--failed", socket=True)
    f.invoke("history/stats", "history", "stats", socket=True)
    f.invoke("history/period", "history", "stats", "--period", "week", socket=True)
    entry = re.search(rb"#(\d+)", listing.stdout)[1].decode()
    f.invoke("history/show", "history", "show", entry, socket=True)
    captured = bytes(range(1, 256)) * 16
    database = Path(f.env["XDG_DATA_HOME"]) / "telar/history.db"
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT OR REPLACE INTO command_output (command_id,content,truncated,observed_bytes) VALUES (?,?,?,?)", (int(entry), captured, 0, len(captured)))
    result = f.invoke("history/show-bytes", "history", "show", entry, socket=True)
    assert result.stdout == captured and not result.stderr
    with sqlite3.connect(database) as connection:
        connection.execute("UPDATE command_output SET truncated=1, observed_bytes=? WHERE command_id=?", (len(captured) + 100, int(entry)))
    result = f.invoke("history/show-truncated", "history", "show", entry, socket=True)
    assert result.stdout == captured and b"output truncated" in result.stderr

    def entries(name):
        lines = f.invoke(name, "history", "list", "--limit", "1000", socket=True).stdout.splitlines()
        return {re.match(rb"#(\d+) ", line)[1].decode(): line for line in lines}

    kept = entries("history/before-delete")
    assert entry in kept and len(kept) > 1
    del kept[entry]
    result = f.invoke("history/delete", "history", "delete", entry, socket=True)
    assert result.stdout == b"removed 1 entries\n"
    assert entries("history/deleted") == kept
    total = f.invoke("history/total", "history", "stats", socket=True).stdout
    assert b"commands: %d\n" % len(kept) in total
    result = f.invoke("history/dry-run", "history", "prune", "--dry-run", socket=True)
    assert result.stdout == b"would remove %d entries (counting at most the newest 1000)\n" % len(kept)
    f.invoke("history/before-preview", "history", "prune", "--dry-run", "--before", "2026-01-01", socket=True)
    for name, answer in (("history/abort", b"no\n"), ("history/abort-eof", b"")):
        assert f.invoke(name, "history", "prune", socket=True, data=answer).stdout.endswith(b"aborted\n")
    assert f.invoke("history/kept-total", "history", "stats", socket=True).stdout == total
    assert entries("history/kept") == kept
    duplicates = {key for key, line in kept.items() if b"duplicate" in line}
    assert duplicates and len(duplicates) < len(kept)
    f.invoke("history/confirm", "history", "prune", "--match", "duplicate", socket=True, data=b" yes \r\n")
    assert entries("history/matched") == {key: line for key, line in kept.items() if key not in duplicates}
    f.invoke("history/prune", "history", "prune", "--yes", socket=True)
    assert f.invoke("history/empty", "history", "list", socket=True).stdout == b""
    history_rows(f)
    history_imports(f)
    large = f.root / "large_history"
    large.write_bytes(b"a" * 65535 + b"\n" + b"b" * 65536 + b"\nprintf kept\n")
    f.invoke("history/import-limit", "history", "import", "bash", "--file", large, socket=True, code=1)
    assert b"printf kept" in f.invoke("history/import-kept", "history", "search", "kept", socket=True).stdout
    reached = limits(f, "limits/reached")
    assert any(entry["name"] == "history.import_command_bytes" for entry in reached["limits"]), reached
    f.invoke("history/final-prune", "history", "prune", "--yes", socket=True)
    batches = f.root / "batch_history"
    batches.write_bytes(b"\n".join(f"printf batch-{index}".encode() for index in range(129)) + b"\n")
    f.invoke("history/import-batches", "history", "import", "bash", "--file", batches, socket=True)
    payload = f.root / "payload_history"
    payload.write_bytes(b"\n".join(bytes([ord('a') + index]) * 65535 for index in range(5)) + b"\n")
    f.invoke("history/import-payloads", "history", "import", "bash", "--file", payload, socket=True)
    stats = f.invoke("history/batch-stats", "history", "stats", socket=True)
    assert b"commands: 134\n" in stats.stdout
    f.invoke("history/cleanup-batches", "history", "prune", "--yes", socket=True)


def projects(f):
    root = f.root / "project"
    recipe = root / ".telar/setup.json"
    recipe.write_text(json.dumps({"version": 1, "argv": [sys.executable, "-c", "import sys;print('prepared');print('error stream',file=sys.stderr)"]}))
    result = f.invoke("project/ready", "project", "setup", "--cwd", root, "--json")
    assert json.loads(result.stdout)["environment"] == "ready" and b"prepared\n" in result.stderr
    recipe.write_text(json.dumps({"version": 1, "argv": [sys.executable, "-c", "import time;time.sleep(.2)"]}))
    f.invoke("project/detach", "project", "setup", "--cwd", root, "--detach")
    recipe.write_text('{"version":1,"argv":["/bin/sh","-c","exit 9"]}')
    f.invoke("project/failure", "project", "setup", "--cwd", root, code=1)
    # Output the runtime no longer holds when the CLI asks for it is reported, not skipped.
    recipe.write_text(json.dumps({"version": 1, "argv": [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'x'*(8<<20))"]}))
    result = f.invoke("project/retention-exceeded", "project", "setup", "--cwd", root, "--json", code=1, timeout=60)
    assert b"SetupOutputRetentionExceeded" in result.stderr and b'"ready"' not in result.stdout, result.stderr[-300:]


def project_recipe_gate(f):
    """A recipe runs as the user only from a file they alone own and reach without links,
    and only within its argument cap."""
    root = f.root / "gated"
    directory = root / ".telar"
    directory.mkdir(parents=True, mode=0o700)
    marker = f.root / "gated-ran"
    program = "import pathlib,sys;pathlib.Path(sys.argv[1]).write_text(str(len(sys.argv)))"

    def recipe(count):
        argv = [sys.executable, "-c", program, str(marker)]
        return json.dumps({"version": 1, "argv": argv + ["pad"] * (count - len(argv))})
    (directory / "setup.json").write_text(recipe(64))
    f.invoke("project/argv-limit", "project", "setup", "--cwd", root)
    assert marker.read_text() == "62"
    marker.unlink()
    (directory / "setup.json").write_text(recipe(65))
    assert b"InvalidProjectRecipe" in f.invoke("project/argv-over-limit", "project", "setup", "--cwd", root, code=1).stderr
    assert not marker.exists()
    # A recipe file over 32 KiB is refused unread; one of exactly 32 KiB runs.
    for size, code in ((32 * 1024 + 1, 1), (32 * 1024, 0)):
        source = recipe(4)
        (directory / "setup.json").write_text(source[:-1] + " " * (size - len(source)) + "}")
        f.invoke(f"project/recipe-size-{size}", "project", "setup", "--cwd", root, code=code)
        assert marker.exists() == (code == 0)
        marker.unlink(missing_ok=True)
    (directory / "setup.json").write_text(recipe(4))
    link = f.root / "gated-link"
    os.link(directory / "setup.json", link)
    f.invoke("project/hardlinked", "project", "setup", "--cwd", root, code=1)
    assert not marker.exists()
    link.unlink()
    directory.chmod(0o777)
    f.invoke("project/shared-directory", "project", "setup", "--cwd", root, code=1)
    assert not marker.exists()
    directory.chmod(0o700)
    directory.rename(f.root / "gated-target")
    directory.symlink_to(f.root / "gated-target", target_is_directory=True)
    f.invoke("project/linked-directory", "project", "setup", "--cwd", root, code=1)
    assert not marker.exists()


def repositories(f, prepare_probe=None):
    source = f.root / "source"
    source.mkdir(mode=0o700)
    f.git(source, "init", "--template=")
    f.git(source, "config", "remote.origin.url", "https://EXAMPLE.test/team/repo.git")
    (source / "payload").write_bytes(bytes(range(256)))
    f.git(source, "add", "payload")
    f.git(source, "commit", "-qm", "Fixture")
    commit = f.git(source, "rev-parse", "HEAD").decode().strip()
    ref = "refs/telar/transfer/fixture"
    f.git(source, "update-ref", ref, commit)
    bundle = f.root / "history.bundle"
    f.git(source, "bundle", "create", bundle, ref)
    content = bundle.read_bytes()
    args = ["repository", "receive", "--identity", "example.test/team/repo", "--transport", "https://EXAMPLE.test/team/repo.git", "--commit", commit, "--ref", ref, "--bytes", len(content)]
    result = f.invoke("repository/receive", *args, data=content)
    prepared = json.loads(result.stdout)
    path = Path(prepared["path"])
    assert prepared["repository_ready"] and not prepared["reused"]
    assert (path / "payload").read_bytes() == bytes(range(256))
    (path / "payload").write_bytes(b"keep dirty destination")
    result = f.invoke("repository/reuse", *args, data=content)
    assert json.loads(result.stdout)["reused"] and (path / "payload").read_bytes() == b"keep dirty destination"
    f.invoke("repository/selected", *args, "--workspace", path, data=content)
    if prepare_probe:
        (source / "uncommitted").write_text("only commits travel")
        result = subprocess.run([str(prepare_probe), str(f.binary)], env=f.env, cwd=source, capture_output=True, timeout=20)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert json.loads(result.stdout)["repository_ready"] and not (path / "uncommitted").exists()
        assert b"1 uncommitted files stay on this machine" in result.stderr
        assert f.git(source, "for-each-ref", "--format=%(refname)", "refs/telar/transfer/").decode().strip() == ref
        tips = f.invoke("repository/tips", "repository", "tips", "--identity", "example.test/team/repo", "--workspace", path).stdout.split()
        assert commit.encode() in tips
        f.invoke("repository/tips-none", "repository", "tips", "--identity", "example.test/team/absent")
        # The clone holds the first commit: only the second one travels.
        (source / "second").write_bytes(os.urandom(4096))
        f.git(source, "add", "second")
        f.git(source, "commit", "-qm", "Second")
        second = f.git(source, "rev-parse", "HEAD").decode().strip()
        result = subprocess.run([str(prepare_probe), str(f.binary)], env=f.env, cwd=source, capture_output=True, timeout=20)
        assert result.returncode == 0, (result.stdout, result.stderr)
        sent = int(re.search(rb"bundle (\d+) bytes", result.stderr).group(1))
        whole = f.root / "whole.bundle"
        f.git(source, "bundle", "create", whole, "HEAD")
        assert sent < whole.stat().st_size, (sent, whole.stat().st_size)
        f.git(path, "cat-file", "-e", second + "^{commit}")
    f.invoke("repository/interrupted", *args, data=content[:-1], code=1)
    f.invoke("repository/long", *args, data=content + b"x", code=1)
    assert not list(path.parent.glob("*.stage"))
    bad = list(args)
    bad[bad.index("--commit") + 1] = "f" * 40
    f.invoke("repository/mismatch", *bad, data=content, code=1)
    assert not list(path.parent.glob("*.stage"))
    closed = f.root / "closed"
    shutil.copytree(path, closed)
    # The history learns of this clone as it does of any directory: a workspace ran there and
    # was closed. The runtime remembers it after the workspace is gone.
    opened = json.loads(f.invoke("repository/open-closed", "workspace", "create", "--directory", closed, "--json", "--", "/bin/cat").stdout)
    f.invoke("repository/close-closed", "tab", "close", opened["tab_id"], "--workspace", opened["workspace_id"])
    listed = json.loads(f.invoke("repository/workspaces", "workspace", "list", "--json").stdout)
    assert str(closed) not in json.dumps(listed), listed
    f.invoke("repository/ambiguous", *args, data=content, code=1)
    result = f.invoke("repository/selected-closed", *args, "--workspace", closed, data=content)
    assert Path(json.loads(result.stdout)["path"]) == closed
    shutil.rmtree(path)
    result = f.invoke("repository/history-closed", *args, data=content)
    assert Path(json.loads(result.stdout)["path"]) == closed and not path.exists()
    stage = Path(str(path) + ".stage")
    stage.mkdir(mode=0o700)
    (stage / "owner").write_text("other repository")
    (stage / "owner").chmod(0o600)
    f.invoke("repository/unowned-stage", *args, data=content, code=1)
    assert stage.exists()
    shutil.rmtree(stage)
    # A lock another local user could redirect or share is refused, and nothing is written through it.
    lock = Path(str(path) + ".lock")
    lock.unlink(missing_ok=True)
    redirected = f.root / "redirected.lock"
    lock.symlink_to(redirected)
    f.invoke("repository/symlink-lock", *args, data=content, code=1)
    assert not redirected.exists() and lock.is_symlink()
    lock.unlink()
    lock.write_bytes(b"")
    lock.chmod(0o644)
    f.invoke("repository/shared-lock", *args, data=content, code=1)
    lock.unlink()
    # A receive killed mid-transfer leaves its own stage behind; the next receive clears it.
    process = subprocess.Popen([str(f.binary), *map(str, args)], env=f.env, cwd=f.root, stdin=subprocess.PIPE,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    process.stdin.write(content[:len(content) // 2])
    process.stdin.flush()
    deadline = time.monotonic() + 10
    while not (stage / "history.bundle").exists() or (stage / "history.bundle").stat().st_size < len(content) // 2:
        assert time.monotonic() < deadline, "the receive did not stage the bundle"
        time.sleep(.02)
    process.kill()
    process.wait()
    process.stdin.close()
    assert (stage / "owner").exists()
    f.invoke("repository/after-crash", *args, data=content)
    assert not list(path.parent.glob("*.stage"))


def dispatch(f):
    """A dispatch to another machine never overwrites commits its clone's branch holds."""
    bindir = f.root / "ssh-bin"
    bindir.mkdir(mode=0o700)
    # The other machine is this one: the remote command runs locally, as sshd would run it, in HOME.
    (bindir / "ssh").write_text('#!/bin/sh\nfor command; do :; done\ncd "$HOME" || exit 255\nexec /bin/sh -c "$command"\n')
    (bindir / "ssh").chmod(0o700)
    profiles = Path(f.env["XDG_CONFIG_HOME"]) / "telar/machines.json"
    profiles.parent.mkdir(mode=0o700, exist_ok=True)
    profiles.write_text(json.dumps({"version": 2, "local_label": "local", "machines": [
        {"id": "m-0123456789ab", "label": "box", "destination": "box", "telar_path": str(f.binary)}]}))
    profiles.chmod(0o600)
    path = f.env["PATH"]
    f.env["PATH"] = f"{bindir}:{path}"
    try:
        source = f.root / "dispatched"
        source.mkdir(mode=0o700)
        f.git(source, "init", "-q", "--template=", "-b", "main")
        f.git(source, "config", "remote.origin.url", "https://example.test/team/dispatched.git")
        f.git(source, "commit", "-q", "--allow-empty", "-m", "Base")
        base = f.git(source, "rev-parse", "HEAD").decode().strip()
        clone = Path(json.loads(f.invoke("dispatch/prepare", "repository", "prepare", "--machine", "box", "--json", cwd=source).stdout)["path"])
        # Work that exists only on the other machine's branch, and diverging work here.
        remote = f.git(clone, "commit-tree", "-p", base, "-m", "Remote work", base + "^{tree}").decode().strip()
        f.git(clone, "update-ref", "refs/heads/feature", remote)
        f.git(source, "switch", "-q", "-c", "feature")
        f.git(source, "commit", "-q", "--allow-empty", "-m", "Local work")
        result = f.invoke("dispatch/diverged", "worktree", "create", "feature", "--machine", "box", cwd=source, code=None)
        assert f.git(clone, "rev-parse", "refs/heads/feature").decode().strip() == remote
        assert result.returncode == 1, (result.returncode, result.stderr)
        # A new branch starts on the other machine at this machine's commit, with its title.
        local = f.git(source, "rev-parse", "HEAD").decode().strip()
        f.invoke("dispatch/create", "worktree", "create", "fresh", "--machine", "box", "--title", "Remote task", cwd=source)
        assert f.git(clone, "rev-parse", "refs/heads/fresh").decode().strip() == local
        listed = json.loads(f.invoke("dispatch/list", "worktree", "list", "--json", cwd=clone).stdout)
        assert [entry["title"] for entry in listed if entry["branch"] == "fresh"] == ["Remote task"], listed
        # Fetching brings the other machine's branch under refs/remotes/MACHINE/.
        fetched = json.loads(f.invoke("dispatch/fetch", "worktree", "fetch", "fresh", "--machine", "box", "--json", cwd=source).stdout)
        assert fetched == {"machine": "box", "branch": "fresh", "ref": "refs/remotes/box/fresh", "commit": local}, fetched
        assert f.git(source, "rev-parse", "refs/remotes/box/fresh").decode().strip() == local
        # A destination Git would split into host, port and path fetches nothing, though the
        # machine names its clone.
        remote_telar = bindir / "telar-colon"
        remote_telar.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps({"path": str(clone)}) + "'\n")
        remote_telar.chmod(0o700)
        machines = json.loads(profiles.read_text())
        machines["machines"].append({"id": "m-0123456789ac", "label": "colon", "destination": "user@host:22", "telar_path": str(remote_telar)})
        profiles.write_text(json.dumps(machines))
        f.invoke("dispatch/fetch-colon", "worktree", "fetch", "fresh", "--machine", "colon", cwd=source, code=1)
        assert not f.git(source, "for-each-ref", "refs/remotes/colon/").strip()
    finally:
        f.env["PATH"] = path


def run_suite(binary, root, with_runtime=True, prepare_probe=None):
    f = Fixture(binary, root)
    offline(f)
    if with_runtime:
        with f.runtime():
            execution(f)
            runtime_queries(f)
            history(f)
            projects(f)
            project_recipe_gate(f)
            repositories(f, prepare_probe)
            dispatch(f)
    return f


def autostart(binary, root):
    f = Fixture(binary, root)
    try:
        result = f.invoke("autostart", "exec", "--id", "2001", "--no-stdin", "--socket", f.socket, "--", "/bin/echo", "boot")
        assert result.stdout == b"boot\n" and result.stderr == b""
    finally:
        f.invoke("autostart/stop", "server", "stop", socket=True)
        deadline = time.monotonic() + 10
        while f.socket.exists():
            assert time.monotonic() < deadline
            time.sleep(.02)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--telar", type=Path, required=True)
    parser.add_argument("--scratch", type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--prepare-probe", type=Path)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="cli-er-", dir=arguments.scratch) as directory:
        fixture = run_suite(arguments.telar, directory, not arguments.offline, arguments.prepare_probe)
        if not arguments.offline:
            autostart(arguments.telar, Path(directory) / "auto")
        print(f"{len(fixture.results)} CLI checks passed")


if __name__ == "__main__":
    main()
