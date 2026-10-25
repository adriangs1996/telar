#!/usr/bin/env python3
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
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


def cases(root):
    events = {
        "claude": ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd", "Notification", "CwdChanged", "unknown"],
        "codex": ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd", "SubagentStop", "unknown"],
        "pi": ["session_start", "agent_settled", "ui_prompt_end", "state_snapshot", "agent_start", "ui_prompt_start", "session_shutdown", "session_info_changed", "tool_execution_start", "tool_execution_end", "unknown"],
        "opencode": ["load", "chat.message", "session.status", "permission.asked", "question.asked", "permission.replied", "question.replied", "question.rejected", "state_snapshot", "tool.execute.before", "tool.execute.after", "session.updated", "dispose", "unknown"],
        "cursor": ["sessionStart", "stop", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "sessionEnd", "unknown"],
    }
    tools = {"claude": "Bash", "codex": "exec_command", "pi": "bash", "opencode": "bash", "cursor": "Shell"}
    for provider, names in events.items():
        key = "event" if provider in ("pi", "opencode") else "hook_event_name"
        for event in names:
            for variant in ("minimal", "populated"):
                payload = {key: event}
                if variant == "populated":
                    payload.update(session_id="session-17", conversation_id="abcd-1234", tool_name=tools[provider],
                                   tool_input={"command": "printf 'héllo\\n'", "cmd": "printf 'héllo\\n'"},
                                   cwd="/tmp", tool_use_id="call-9", tool_call_id="call-9", name="Named Pi", title="Named OpenCode",
                                   session_title="Named Claude", last_assistant_message="  Done\n\tall\x1b[0m  ",
                                   notification_type="permission_prompt", message="Allow?\nextra", exit_code=7,
                                   tool_output='{"output":"ok","exitCode":7}', workspace_roots=["/tmp"], transcript_path="/tmp/missing.jsonl")
                yield {"name": f"{provider}/{event}/{variant}", "provider": provider, "input": payload}

    for provider in events:
        for payload in (b"{", b"[]", b"null", b'{"cwd":null}', b'{"tool_name":17}', b'{"cwd":"/tmp","cwd":"/"}'):
            yield {"name": f"{provider}/invalid/{payload.hex()}", "provider": provider, "input": payload}
    for provider in ("claude", "codex"):
        for event in ("PreToolUse", "PostToolUse", "Stop", "SubagentStop", "SessionStart"):
            for agent in (None, "", "child-1"):
                yield {"name": f"{provider}/subagent/{event}/{agent}", "provider": provider,
                       "input": {"hook_event_name": event, "agent_id": agent, "session_id": "root", "transcript_path": "/tmp/rollout-root.jsonl"}}
    for tool, tool_input in (("AskUserQuestion", {"questions": [{"question": "Continue?\nnext"}]}), ("ExitPlanMode", {}),
                             ("TaskCreate", {"subject": "Implement\tcarefully\nnext"}), ("TaskUpdate", {"taskId": "2", "status": "completed"}),
                             ("TodoWrite", {"todos": [{"content": "one", "status": "completed"}, {"content": "two", "activeForm": "Doing two", "status": "in_progress"}]}),
                             ("update_plan", {"plan": [{"step": "one", "status": "pending"}]})):
        for event in ("PreToolUse", "PostToolUse"):
            yield {"name": f"plan/{tool}/{event}", "provider": "claude", "input": {"hook_event_name": event, "tool_name": tool, "tool_input": tool_input}}
    for refusal in (0x42, 0x40, 0x20, 0x2b):
        yield {"name": f"refused/{refusal}", "provider": "claude", "refusal": refusal,
               "input": {"hook_event_name": "SessionStart", "session_title": "Hello", "cwd": "/tmp"}}
    for key in ("TELAR_PANE_ID", "TELAR_PANE_GENERATION"):
        for value in (None, "", "invalid", "18446744073709551616", "0", "+17", "1_7", "1__7", "17_", "_17", "-17", "18446744073709551615"):
            yield {"name": f"environment/{key}/{value}", "provider": "claude", "environment": {key: value}, "input": {"hook_event_name": "SessionStart"}}

    for provider in events:
        key = "event" if provider in ("pi", "opencode") else "hook_event_name"
        event = events[provider][0]
        for field, value in (("session_id", "-unsafe"), ("session_id", "bad name"), ("session_id", "x" * 65),
                             ("agent_id", None), ("agent_id", ""), ("agent_id", "nested"),
                             ("title", "x" * 95 + "🐢"), ("session_title", "x" * 95 + "🐢"),
                             ("name", "name\ncontrol"), ("busy", None), ("blocked", None)):
            yield {"name": f"fields/{provider}/{field}/{value}", "provider": provider,
                   "input": {key: event, "session_title": "Named", field: value}}
        yield {"name": f"unknown-duplicate/{provider}", "provider": provider,
               "input": ('{"' + key + '":"' + event + '","ignored":1,"ignored":2}').encode()}
        yield {"name": f"escaped-key/{provider}", "provider": provider,
               "input": ('{"' + key.replace('e', '\\u0065') + '":"' + event + '"}').encode()}

    for blocked in ("none", "permission", "question", "plan", "other"):
        for event in ("state_snapshot", "tool.execute.before", "permission.asked", "question.asked"):
            yield {"name": f"opencode/blocked/{blocked}/{event}", "provider": "opencode",
                   "input": {"event": event, "blocked": blocked, "busy": True, "tool_name": "bash", "tool_input": {"command": "echo yes", "questions": [{"question": "Which?"}]}}}
    for title in ("New session - 2026-01-02T12:34:56.789Z", "Child session - 2026-01-02T12:34:56.789Z", "New session - invalid", "", None):
        yield {"name": f"opencode/title/{title}", "provider": "opencode", "input": {"event": "session.updated", "title": title}}

    for tasks in ([], [{"type": "subagent", "status": "running"}], [{"type": "shell", "status": "running"}],
                  [{"type": "subagent", "status": "completed"}, {"type": "subagent", "status": "running"}], [None], [{"type": None}]):
        yield {"name": f"claude/tasks/{tasks}", "provider": "claude", "input": {"hook_event_name": "Stop", "background_tasks": tasks}}
    for payload in (b'{"hook_event_name":"SessionStart","agent_id":null,"agent_id":null}',
                    b'{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"one","command":"two"}}',
                    b'{"hook_event_name":"Stop","last_assistant_message":"bad\\ud800"}',
                    b'{"hook_event_name":"Stop","ignored":"bad\\ud800"}'):
        yield {"name": f"json/{payload.hex()}", "provider": "claude", "input": payload}
    for identifier in ("+2", "0", "65535", "65536", "1_2", "2.0"):
        yield {"name": f"plan/index/{identifier}", "provider": "claude",
               "input": {"hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_input": {"taskId": identifier, "status": "completed"}}}

    codex = root / "codex"
    codex.mkdir()
    for name in ("state_1.sqlite", "state_7.sqlite", "state_0009.sqlite", "state_2_0.sqlite", "state_bad.sqlite"):
        (codex / name).touch()
    yield {"name": "codex/database", "provider": "codex", "input": {"hook_event_name": "SessionStart", "state_database": "ignored"}}
    rollout = root / "rollout-root.jsonl"
    activity = lambda kind, child: '{"item":{"type":"SubAgentActivity","kind":"' + kind + '","agent_thread_id":"' + child + '"}}\n'
    rollout.write_text('x' * 65520 + activity("started", "child-1") + activity("started", "child-2") + activity("completed", "child-1"))
    for event, agent in (("Stop", None), ("Interrupt", None), ("SubagentStop", "child-2"), ("SubagentStop", "child-3")):
        yield {"name": f"codex/rollout/{event}/{agent}", "provider": "codex", "input": {"hook_event_name": event, "session_id": "root", "agent_id": agent, "transcript_path": str(rollout)}}
    linked = root / "linked.jsonl"
    linked.symlink_to(rollout)
    yield {"name": "codex/rollout-symlink", "provider": "codex", "input": {"hook_event_name": "Stop", "transcript_path": str(linked)}}
    cursor = root / "cursor" / "chats" / hashlib.md5(b"/tmp/workspace").hexdigest() / "abcd-1234"
    cursor.mkdir(parents=True)
    (cursor / "meta.json").write_text('{"title":"Fixture"}')
    for workspace in ("/tmp/workspace", "/tmp/other", ""):
        yield {"name": f"cursor/metadata/{workspace}", "provider": "cursor", "input": {"hook_event_name": "beforeSubmitPrompt", "conversation_id": "abcd-1234", "workspace_roots": [workspace]}}

    oversized = b'{"hook_event_name":"SessionStart","session_title":"Preserved","tool_input":{"content":"' + b'x' * (16 * 1024 * 1024) + b'"}}'
    yield {"name": "input/oversized", "provider": "claude", "input": oversized}
    yield {"name": "input/oversized-outside-pane", "provider": "claude", "input": oversized, "environment": {"TELAR_PANE_ID": None}}
    yield {"name": "input/oversized-malformed-tail", "provider": "claude", "input": b'{"hook_event_name":"SessionStart","bad":[1,],"padding":"' + b'x' * (16 * 1024 * 1024)}
    yield {"name": "input/oversized-unicode-tail", "provider": "claude", "input": b'{"hook_event_name":"SessionStart","bad":"\\ud800","padding":"' + b'x' * (16 * 1024 * 1024)}
    yield {"name": "input/oversized-after-object", "provider": "claude", "input": b'{"hook_event_name":"SessionStart"}' + b' ' * (16 * 1024 * 1024)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--filter", default=".")
    arguments = parser.parse_args()
    report = {"measured_at": datetime.now(timezone.utc).isoformat(), "acceptance": "equivalence_only", "filter": arguments.filter, "binaries": {}, "cases": [], "differences": []}
    for implementation in ("zig", "cpp"):
        binary = getattr(arguments, implementation).resolve()
        report["binaries"][implementation] = {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="telar-hooks-", dir="/tmp") as directory:
        for case in cases(Path(directory)):
            if not re.search(arguments.filter, case["name"]):
                continue
            entry = {"name": case["name"]}
            for implementation in ("zig", "cpp"):
                entry[implementation], entry[f"{implementation}_ns"] = run_case(getattr(arguments, implementation).resolve(), Path(directory), case)
            entry["equal"] = entry["zig"] == entry["cpp"]
            report["cases"].append(entry)
            if not entry["equal"]:
                report["differences"].append(case["name"])
            arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"cases": len(report["cases"]), "differences": report["differences"]}))
    raise SystemExit(bool(report["differences"]))


if __name__ == "__main__":
    main()
