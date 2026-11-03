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

    def invoke(self, name, *args, data=b"", code=0, cwd=None, socket=False):
        argv = [str(self.binary), *map(str, args)]
        if socket:
            argv += ["--socket", str(self.socket)]
        result = subprocess.run(argv, env=self.env, input=data, capture_output=True, cwd=cwd or self.root, timeout=20)
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


def fixture_query(f, name, arguments, frames, code=0):
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

    f.socket.unlink(missing_ok=True)
    try:
        with socket.socket(socket.AF_UNIX) as listener, ThreadPoolExecutor(max_workers=1) as worker:
            listener.bind(str(f.socket))
            listener.listen()
            listener.settimeout(5)
            future = worker.submit(serve, listener)
            result = f.invoke(name, *arguments, socket=True, code=code)
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
    fixture_query(f, "fixture/metrics-json", ["runtime", "metrics", "--json"], [metrics])
    fixture_query(f, "fixture/metrics-text", ["runtime", "metrics"], [metrics])
    fixture_query(f, "fixture/metrics-no-battery-json", ["runtime", "metrics", "--json"], [no_battery])
    fixture_query(f, "fixture/metrics-no-battery-text", ["runtime", "metrics"], [no_battery])
    fixture_query(f, "fixture/status-port", ["runtime", "status"], [proxy])
    fixture_query(f, "fixture/watch", ["runtime", "watch", "--count", "4"], [proxy, metrics, workspace, agents])
    fixture_query(f, "fixture/proxy-filter", ["proxy", "watch", "--count", "1"], [metrics, workspace, agents, proxy])
    fixture_query(f, "fixture/proxy-stop", ["proxy", "watch"], [metrics, proxy, bytes([0x85])])
    resync = bytes([0x93]) + struct.pack("<BQBB", 0, 7, 0, 0)
    fixture_query(f, "fixture/resync", ["runtime", "watch"], [proxy, resync], code=1)

    def text(value):
        encoded = value.encode()
        return struct.pack("<H", len(encoded)) + encoded
    workspace_entry = struct.pack("<Q", 7) + text('Work "one"') + text(str(f.root)) + struct.pack("<H", 1) + text("main") + bytes([1])
    workspace = bytes([0x98]) + struct.pack("<QH", 12, 1) + workspace_entry + struct.pack("<H", 0)
    agent_entry = struct.pack("<QQBQQHI", 1, 2, 0, 7, 3, 1, 123) + bytes(range(16))
    agent_entry += text("Workspace") + text("Tab") + text('A "title"') + bytes([2, 2]) + text("checkout")
    agent_entry += bytes([1]) + text("claude") + text("Claude Code") + text("") + bytes([0, 2, 2]) + text("Needs input")
    agent_entry += struct.pack("<IBBBQqqQ", 5, 3, 1, 100, 1, 1000, 2000, 0)
    agent_entry += text('line\nquote"') + struct.pack("<HH", 1, 2) + text("Review")
    agents = bytes([0x96]) + struct.pack("<QH", 13, 1) + agent_entry
    fixture_query(f, "fixture/snapshots", ["runtime", "watch", "--count", "2"], [workspace, agents])


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
    if contract["schema_version"] == "cqp00001":
        assert contract["fingerprint"] == b"cqp00001".hex()
        source = Path(__file__).resolve().parents[3] / "dlls/telar-client/include/telar_client/serializers/telar_messages.hpp"
        for enum, key in (("ClientTag", "client_requests"), ("ServerTag", "server_messages"), ("AgentStatus", "agent_statuses")):
            body = re.search(r"enum class " + enum + r" : Byte \{(.*?)\n  \};", source.read_text(), re.S)[1]
            entries = {name: int(value, 0) for name, value in re.findall(r"(\w+)\s*=\s*(0x[0-9a-f]+|\d+)", body)}
            assert contract[key] == entries
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
    f.invoke("file/limit", "file", "put", f.root / "large", "--bytes", 128 * 1024 * 1024 + 1, code=1)

    for name, content in (("s.runtime-11.log", b"old\nsecond\nlast\x08\x0c\x7f\n"),
                          ("s.client-42.log", b"one\ntwo\n"), ("s.client-42.log.1", b"ignored\n"),
                          ("s.runtime.log", b"runtime\n"), ("s.runtime.start.log", b"start\n")):
        (f.root / name).write_bytes(content)
    f.invoke("logs/text", "diagnostics", "logs", "--lines", "2", socket=True)
    logs = json.loads(f.invoke("logs/json", "diagnostics", "logs", "--lines", "2", "--json", socket=True).stdout)
    assert len(logs) == 4
    assert [Path(item["path"]).name for item in logs] == sorted(Path(item["path"]).name for item in logs)
    f.invoke("logs/pid", "diagnostics", "logs", "--pid", "42", "--json", socket=True)
    f.invoke("logs/component", "diagnostics", "logs", "--component", "client", socket=True)
    f.invoke("logs/missing", "diagnostics", "logs", "--pid", "999", socket=True, code=2)
    (f.root / "s.runtime.log").unlink()
    (f.root / "s.runtime.log").symlink_to(path)
    f.invoke("logs/unsafe", "diagnostics", "logs", socket=True, code=1)
    (f.root / "s.runtime.log").unlink()

    checkout = f.root / "project"
    checkout.mkdir(mode=0o700)
    f.invoke("project/absent", "project", "setup", "--cwd", checkout)
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
               '{"version":1,"argv":,}', '{"version":1,,', '']
    for index, recipe in enumerate(recipes):
        (checkout / ".telar/setup.json").write_text(recipe)
        f.invoke(f"project/invalid-{index}", "project", "setup", "--cwd", checkout, code=1)
    f.invoke("repository/invalid", "repository", "receive", "--transport", "https://example.test/p.git", "--identity", "wrong", code=1)


def execution(f):
    common = ("--socket", str(f.socket))
    data = bytes(range(256)) * 257
    program = "import sys; d=sys.stdin.buffer.read();sys.stdout.buffer.write(d);sys.stderr.buffer.write(d[::-1]);sys.exit(7)"
    result = f.invoke("exec/streams", "exec", "--id", "1001", *common, "--", sys.executable, "-c", program, data=data, code=7)
    assert result.stdout == data and result.stderr == data[::-1]
    status = json.loads(f.invoke("exec/status", "exec", "status", "1001", socket=True).stdout)
    assert status["state"] == "exited" and status["stdin_bytes"] == len(data)
    output = f.invoke("exec/output", "exec", "output", "1001", socket=True)
    assert output.stdout == data and output.stderr == data[::-1]
    output = f.invoke("exec/offset", "exec", "output", "1001", "--stdout-offset", "3", "--stderr-offset", "5", socket=True)
    assert output.stdout == data[3:] and output.stderr == data[::-1][5:]
    f.invoke("exec/missing", "exec", "status", "9999", socket=True, code=125)
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
    f.invoke("limits/json", "diagnostics", "limits", "--json", socket=True)
    f.invoke("limits/text", "diagnostics", "limits", socket=True)


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
    f.invoke("history/delete", "history", "delete", entry, socket=True)
    f.invoke("history/dry-run", "history", "prune", "--dry-run", socket=True)
    f.invoke("history/before-preview", "history", "prune", "--dry-run", "--before", "2026-01-01", socket=True)
    f.invoke("history/abort", "history", "prune", socket=True, data=b"no\n")
    f.invoke("history/confirm", "history", "prune", "--match", "duplicate", socket=True, data=b" yes \r\n")
    f.invoke("history/prune", "history", "prune", "--yes", socket=True)
    assert f.invoke("history/empty", "history", "list", socket=True).stdout == b""
    large = f.root / "large_history"
    large.write_bytes(b"a" * 65535 + b"\n" + b"b" * 65536 + b"\nprintf kept\n")
    f.invoke("history/import-limit", "history", "import", "bash", "--file", large, socket=True, code=1)
    assert b"printf kept" in f.invoke("history/import-kept", "history", "search", "kept", socket=True).stdout
    f.invoke("limits/reached", "diagnostics", "limits", "--json", socket=True)
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
    f.invoke("repository/interrupted", *args, data=content[:-1], code=1)
    f.invoke("repository/long", *args, data=content + b"x", code=1)
    assert not list(path.parent.glob("*.stage"))
    bad = list(args)
    bad[bad.index("--commit") + 1] = "f" * 40
    f.invoke("repository/mismatch", *bad, data=content, code=1)
    assert not list(path.parent.glob("*.stage"))
    closed = f.root / "closed"
    shutil.copytree(path, closed)
    database = Path(f.env["XDG_DATA_HOME"]) / "telar/history.db"
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO session (id,pane_id,location_kind,location_id,tab_id,workspace_path,shell,started_at_ms,finished_at_ms) VALUES (?,?,?,?,?,?,?,?,?)",
                           (bytes([42]) * 16, 901, 0, 901, 1, str(closed), "/bin/sh", 0, 1))
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


def run_suite(binary, root, with_runtime=True, prepare_probe=None):
    f = Fixture(binary, root)
    offline(f)
    if with_runtime:
        with f.runtime():
            execution(f)
            runtime_queries(f)
            history(f)
            projects(f)
            repositories(f, prepare_probe)
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
