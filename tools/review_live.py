#!/usr/bin/env python3
"""Run the isolated change-review experiment against an authenticated Codex CLI.

`start` makes a real model call; `load` only reads the experiment socket. This is
an external observation worker, not Telar's production runtime or hook API.
"""

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time

SCHEMA = 1
MAX_FRAME = 256 * 1024
MAX_PATCH = 48 * 1024
MAX_COMMENTS = 32
MAX_BODY = 2048
MAX_SOURCE_LINES = 480
TURN_SECONDS = 120
SOURCE_NAME = "slug.py"
BASE_SOURCE = ('def slugify(text: str) -> str:\n'
               '    """Create a URL fragment from a label."""\n'
               '    return text\n')
INITIAL_PROMPT = ("This is a small, isolated change-review experiment. Edit only slug.py with "
                  "the apply_patch file-edit tool. Keep the signature and docstring. Replace "
                  "the return statement with exactly these two lines:\n"
                  "    normalized = text.lower()\n"
                  "    return normalized.replace(\" \", \"-\")\n"
                  "Do not improve this first iteration, create other files, run commands, "
                  "or delegate work. A human review will follow in this same session. "
                  "Finish with a short description of the edit.\n\nCurrent complete slug.py:\n```python\n" + BASE_SOURCE + "```\n")


class ReviewError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ReviewError(message)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def atomic_json(path, value):
    pending = path.with_name(path.name + ".pending")
    descriptor = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(path)


def bounded_text(path, limit=MAX_PATCH):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "Source must be a regular file")
        value = stream.read(limit + 1)
    require(len(value) <= limit, "Source exceeds experiment byte limit")
    require(b"\0" not in value, "Binary files are not supported by this experiment")
    try:
        return value.decode("utf-8")
    except UnicodeError as error:
        raise ReviewError("Source must be UTF-8") from error


def verify_provider_patches(before, after, changes):
    with tempfile.TemporaryDirectory(prefix="telar-review-patch-") as temporary:
        source = Path(temporary) / SOURCE_NAME
        source.write_text(before)
        for evidence in changes:
            patch = evidence["change"]["diff"]
            require(patch.startswith("@@ "), "Unsupported provider patch format")
            framed = "--- a/slug.py\n+++ b/slug.py\n" + patch
            result = subprocess.run(["git", "apply", "--unidiff-zero", "--whitespace=nowarn", "-"],
                                    input=framed.encode(), cwd=temporary, capture_output=True, timeout=10,
                                    env={key: value for key, value in os.environ.items() if not key.startswith("GIT_")})
            require(result.returncode == 0, "Provider patch cannot be applied to the retained source")
        require(bounded_text(source) == after, "Provider patches do not reproduce the captured source")


def make_revision(before, after, turn, thread_id):
    require(before != after, "The agent completed without changing the source")
    require(turn.get("thread_id") == thread_id, "File evidence belongs to a different session")
    require(len(before.splitlines()) <= MAX_SOURCE_LINES and len(after.splitlines()) <= MAX_SOURCE_LINES,
            "Source exceeds the review widget line capacity")
    file_items = [item for item in turn["items"] if item.get("type") == "fileChange"]
    changes = [item for item in file_items if item.get("status") == "completed"]
    require(bool(changes), "No completed fileChange event supports this revision")
    observed = []
    for item in changes:
        require(item.get("status") == "completed", "File edit was not completed successfully")
        require(bool(item.get("changes")), "File edit contains no file evidence")
        for change in item["changes"]:
            path = Path(change.get("path", ""))
            require(path == Path(turn["cwd"]) / SOURCE_NAME or str(path) == SOURCE_NAME,
                    "File edit evidence targets a different file")
            kind = change.get("kind", {})
            require(kind.get("type") == "update" and kind.get("move_path") is None,
                    "Only in-place source updates are supported")
            require(isinstance(change.get("diff"), str) and bool(change["diff"]),
                    "File edit evidence has no patch")
            observed.append(dict(item_id=item["id"], change=change))
    verify_provider_patches(before, after, observed)
    require(before.endswith("\n") and after.endswith("\n"), "Source must end with a newline")
    patch = "diff --git a/slug.py b/slug.py\n" + "".join(difflib.unified_diff(
        before.splitlines(keepends=True), after.splitlines(keepends=True),
        fromfile="a/slug.py", tofile="b/slug.py", n=max(len(before.splitlines()), len(after.splitlines()))))
    require(len(patch.encode()) <= MAX_PATCH, "Patch exceeds experiment byte limit")
    identity = digest((thread_id + "\0" + turn["id"] + "\0" + patch).encode())
    return dict(id=identity, patch=patch, before=before, after=after,
                before_hash=digest(before.encode()), after_hash=digest(after.encode()),
                thread_id=thread_id, turn_id=turn["id"], evidence=observed,
                failed_edits=[item for item in file_items if item.get("status") != "completed"],
                capture="isolated single-writer turn snapshots; not per-tool snapshots")


def validate_request(request, revision):
    require(isinstance(request, dict) and request.get("schema") == SCHEMA, "Unsupported review schema")
    require(request.get("action") == "submit", "Expected submit action")
    request_id = request.get("request_id")
    require(isinstance(request_id, str) and 0 < len(request_id.encode()) <= 64,
            "Request identity must contain 1 to 64 bytes")
    require(request.get("revision_id") == revision["id"], "Review refers to a stale revision")
    comments = request.get("comments")
    require(isinstance(comments, list) and 0 < len(comments) <= MAX_COMMENTS,
            "Submit between 1 and 32 comments")
    for comment in comments:
        require(isinstance(comment, dict), "Invalid comment")
        require(set(comment) == {"file", "side", "first_line", "last_line", "body"}, "Invalid comment fields")
        require(comment["file"] == SOURCE_NAME, "Comment targets an unknown file")
        require(comment["side"] in ("before", "after"), "Invalid comment side")
        first, last = comment["first_line"], comment["last_line"]
        require(type(first) is int and type(last) is int, "Comment boundaries must be line numbers")
        lines = revision[comment["side"]].splitlines()
        require(1 <= first <= last <= len(lines), "Comment range is outside the retained source")
        body = comment["body"]
        require(isinstance(body, str) and bool(body.strip()) and "\0" not in body and
                len(body.encode()) <= MAX_BODY, "Comment body must contain 1 to 2048 UTF-8 bytes")
    return digest(json.dumps(request, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode())


def feedback_prompt(request, revision):
    lines = ["Apply this human review to your previous edit of slug.py in this same session.",
             "Edit only slug.py with apply_patch. Do not create files or delegate work.",
             "The comments below refer to the retained revision; preserve the public signature.",
             "Review ID: " + request["request_id"], "Revision ID: " + revision["id"]]
    for comment in request["comments"]:
        source = revision[comment["side"]].splitlines()
        snippet = "\n".join(source[comment["first_line"] - 1:comment["last_line"]])
        lines.extend([f"{comment['file']} {comment['side']} lines {comment['first_line']}-{comment['last_line']}",
                      "```python", snippet, "```", comment["body"]])
    return "\n\n".join(lines)


class CodexSession:
    def __init__(self, binary, directory):
        self.directory = directory
        self.cwd = directory / "workspace"
        self.buffer = b""
        self.request_id = 0
        self.pending = []
        self.thread_id = ""
        self.log = (directory / "provider.stderr.log").open("wb")
        env = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        self.child = subprocess.Popen([binary, "app-server", "--listen", "stdio://"],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                      env=env, cwd=self.cwd, start_new_session=True)
        (directory / "provider.pid").write_text(str(self.child.pid))

    def send(self, value):
        data = json.dumps(value, ensure_ascii=False).encode() + b"\n"
        require(len(data) <= MAX_FRAME, "Provider request exceeds experiment limit")
        self.child.stdin.write(data)
        self.child.stdin.flush()

    def receive(self, deadline):
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Codex operation timed out")
            if not select.select([self.child.stdout], [], [], min(remaining, 1))[0]:
                continue
            data = os.read(self.child.stdout.fileno(), 65536)
            require(bool(data), "Codex exited before completing the operation")
            self.buffer += data
            require(len(self.buffer) <= MAX_FRAME, "Provider frame exceeds experiment limit")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def rpc(self, method, params):
        self.request_id += 1
        identity = self.request_id
        self.send(dict(id=identity, method=method, params=params))
        deadline = time.monotonic() + 45
        while True:
            message = self.receive(deadline)
            if message.get("id") == identity and "method" not in message:
                require("error" not in message, f"Codex rejected {method}: {message.get('error')}")
                return message["result"]
            self.handle_request(message)
            self.pending.append(message)
            require(len(self.pending) <= 512, "Too many provider startup events")

    def handle_request(self, message):
        if "id" in message and "method" in message:
            self.send(dict(id=message["id"], error=dict(code=-32601, message="Unsupported experiment request")))
            raise ReviewError("Codex requested an unsupported approval or client tool")

    def start(self, retained_id=None):
        self.rpc("initialize", dict(clientInfo=dict(name="telar-review-experiment", title="Telar review experiment", version="1"),
                                    capabilities=dict(experimentalApi=True)))
        self.send(dict(method="initialized"))
        catalog = self.rpc("model/list", dict(limit=16, includeHidden=False))["data"]
        params = dict(cwd=str(self.cwd), approvalPolicy="never", approvalsReviewer="user", sandbox="workspace-write")
        if retained_id:
            params.update(threadId=retained_id, excludeTurns=True)
        thread = self.rpc("thread/resume" if retained_id else "thread/start", params)
        self.thread_id = thread["thread"]["id"]
        require(len(self.thread_id.encode()) <= 64, "Provider thread identity exceeds bridge limit")
        require(retained_id is None or self.thread_id == retained_id, "Codex resumed a different session")
        self.model = thread.get("model")
        model = next((value for value in catalog if value["model"] == self.model), None)
        require(model is not None, "Configured model is absent from the provider catalog")
        supported = [value["reasoningEffort"] for value in model["supportedReasoningEfforts"]]
        self.effort = "low" if "low" in supported else model["defaultReasoningEffort"]
        atomic_json(self.directory / "session.json", dict(session_id=self.thread_id, model=self.model,
                                                        effort=self.effort, provider_pid=self.child.pid,
                                                        sandbox="workspace-write", approval_policy="never"))

    def turn(self, prompt):
        self.pending.clear()
        params = dict(threadId=self.thread_id, input=[dict(type="text", text=prompt)], model=self.model,
                      effort=self.effort, approvalPolicy="never", approvalsReviewer="user",
                      sandboxPolicy=dict(type="workspaceWrite", writableRoots=[str(self.cwd)],
                                         networkAccess=False, excludeSlashTmp=True, excludeTmpdirEnvVar=True))
        result = self.rpc("turn/start", params)
        identity = result["turn"]["id"]
        captured = dict(id=identity, thread_id=self.thread_id, cwd=str(self.cwd), items=[], messages=[], status="running")
        deadline = time.monotonic() + TURN_SECONDS
        while True:
            event = self.pending.pop(0) if self.pending else self.receive(deadline)
            self.handle_request(event)
            value = event.get("params", {})
            if value.get("threadId") != self.thread_id:
                continue
            method = event.get("method")
            if method == "item/completed" and value.get("turnId") == identity:
                item = value["item"]
                if item.get("type") == "fileChange":
                    captured["items"].append(item)
                elif item.get("type") == "agentMessage":
                    captured["messages"].append(item.get("text", ""))
                    require(sum(len(text.encode()) for text in captured["messages"]) <= 64 * 1024,
                            "Agent response exceeds experiment byte limit")
                require(len(captured["items"]) <= 32 and len(captured["messages"]) <= 64,
                        "Turn exceeds experiment event limit")
            elif method == "turn/completed" and value.get("turn", {}).get("id") == identity:
                captured["status"] = value["turn"]["status"]
                atomic_json(self.directory / ("turn-" + digest(identity.encode()) + ".json"), captured)
                require(captured["status"] == "completed", "Codex turn did not complete successfully")
                return captured

    def close(self):
        if self.child.poll() is None:
            os.killpg(self.child.pid, signal.SIGTERM)
            try:
                self.child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.child.pid, signal.SIGKILL)
                self.child.wait()
        self.log.close()


class Review:
    def __init__(self, directory, provider):
        self.directory = directory
        self.provider = provider
        self.revisions = []
        self.comments = []
        self.submitted = None
        self.status = "reviewable"
        self.error = None
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)

    def capture(self, before, turn):
        after = bounded_text(self.directory / "workspace" / SOURCE_NAME)
        revision = make_revision(before, after, turn, self.provider.thread_id)
        with self.lock:
            index = len(self.revisions)
            require(index < 2, "Experiment retains at most two revisions")
            if index == 1:
                require(self.status == "working" and self.submitted is not None,
                        "A correction requires a submitted review")
            atomic_json(self.directory / f"revision-{index}.json", revision)
            (self.directory / f"revision-{index}.diff").write_text(revision["patch"])
            self.revisions.append(revision)
            if index == 1:
                self.status = "complete"
                self.submitted["delivery"] = "completed"
                self.changed.notify_all()
            return revision

    def restore(self):
        for index in range(2):
            path = self.directory / f"revision-{index}.json"
            if path.exists():
                revision = json.loads(bounded_text(path, MAX_FRAME))
                require(revision["thread_id"] == self.provider.thread_id, "Retained revision belongs to another session")
                verify_provider_patches(revision["before"], revision["after"], revision["evidence"])
                self.revisions.append(revision)
        require(bool(self.revisions), "No retained review is available")
        submitted = self.directory / "submission.json"
        if submitted.exists():
            self.submitted = json.loads(bounded_text(submitted, MAX_FRAME))
            fingerprint = validate_request(self.submitted["request"], self.revisions[0])
            require(fingerprint == self.submitted["fingerprint"], "Retained submission identity changed")
            self.comments = self.submitted["request"]["comments"]
            if self.submitted["delivery"] == "completed" and len(self.revisions) == 2:
                self.status = "complete"
            else:
                self.status = "error"
                self.error = "Previous review delivery failed or is unknown; no turn was retried"
                self.submitted["delivery"] = "failed_or_unknown"
                atomic_json(submitted, self.submitted)
        self.save()

    def snapshot(self):
        with self.lock:
            result = dict(schema=SCHEMA, session_id=self.provider.thread_id,
                          revisions=[dict(id=value["id"], patch=value["patch"]) for value in self.revisions],
                          comments=self.comments, status=self.status)
            if self.error:
                result["error"] = self.error
            return result

    def save(self):
        with self.lock:
            atomic_json(self.directory / "state.json", self.snapshot())

    def submit(self, request):
        with self.lock:
            fingerprint = validate_request(request, self.revisions[0])
            if self.submitted:
                require(self.submitted["request"]["request_id"] == request["request_id"] and
                        self.submitted["fingerprint"] == fingerprint, "A different review has already been submitted")
                return self.snapshot()
            require(self.status == "reviewable" and len(self.revisions) == 1, "This revision is no longer reviewable")
            current = bounded_text(self.directory / "workspace" / SOURCE_NAME)
            require(digest(current.encode()) == self.revisions[0]["after_hash"], "Source changed since the retained review")
            self.submitted = dict(request=request, fingerprint=fingerprint, delivery="dispatching")
            atomic_json(self.directory / "submission.json", self.submitted)
            self.comments = request["comments"]
            self.status = "working"
            self.save()
        prompt = feedback_prompt(request, self.revisions[0])
        (self.directory / "feedback.txt").write_text(prompt)
        try:
            turn = self.provider.turn(prompt)
            self.capture(current, turn)
        except Exception as error:
            with self.lock:
                self.status = "error"
                self.error = str(error).encode()[:256].decode("utf-8", errors="ignore")
                self.submitted["delivery"] = "failed_or_unknown"
                self.changed.notify_all()
        with self.lock:
            atomic_json(self.directory / "submission.json", self.submitted)
            self.save()
            return self.snapshot()

    def handle(self, request):
        require(isinstance(request, dict) and request.get("schema") == SCHEMA, "Unsupported review schema")
        if request.get("action") == "load":
            return self.snapshot()
        if request.get("action") == "wait":
            with self.changed:
                self.changed.wait_for(lambda: self.status != "working", timeout=TURN_SECONDS + 30)
                return self.snapshot()
        return self.submit(request)


def read_exact(stream, length):
    result = bytearray()
    while len(result) < length:
        block = stream.recv(length - len(result))
        require(bool(block), "Review connection closed before the frame completed")
        result.extend(block)
    return bytes(result)


def read_frame(stream):
    length = struct.unpack("<I", read_exact(stream, 4))[0]
    require(0 < length <= MAX_FRAME, "Invalid review frame length")
    return json.loads(read_exact(stream, length))


def write_frame(stream, value):
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    require(len(data) <= MAX_FRAME, "Review response exceeds frame limit")
    stream.sendall(struct.pack("<I", len(data)) + data)


def request(socket_path, value):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(TURN_SECONDS + 60)
        stream.connect(str(socket_path))
        write_frame(stream, value)
        return read_frame(stream)


def serve_client(stream, review, capacity):
    try:
        with stream:
            stream.settimeout(15)
            try:
                response = review.handle(read_frame(stream))
            except Exception as error:
                response = dict(review.snapshot(), status="error", error=str(error).encode()[:256].decode("utf-8", errors="ignore"))
            try:
                write_frame(stream, response)
            except (OSError, ReviewError):
                pass
    finally:
        capacity.release()


def serve(directory, binary, resume_existing=False):
    require(len(str(directory / "review.sock").encode()) < 100, "Use a short experiment path under /tmp")
    retained_id = None
    if resume_existing:
        info = directory.stat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
                "Retained experiment directory must be private and owned by this user")
        retained_id = json.loads(bounded_text(directory / "session.json"))["session_id"]
        require(not (directory / "review.sock").exists(), "Another coordinator socket still exists")
    else:
        directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        workspace = directory / "workspace"
        workspace.mkdir(mode=0o700)
        (workspace / SOURCE_NAME).write_text(BASE_SOURCE)
    (directory / "coordinator.pid").write_text(str(os.getpid()))
    provider = CodexSession(binary, directory)
    server = None
    capacity = threading.BoundedSemaphore(4)
    try:
        provider.start(retained_id)
        review = Review(directory, provider)
        if resume_existing:
            review.restore()
        else:
            review.capture(BASE_SOURCE, provider.turn(INITIAL_PROMPT))
            review.save()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(directory / "review.sock"))
        os.chmod(directory / "review.sock", 0o600)
        server.listen(4)
        print(json.dumps(dict(ready=True, socket=str(directory / "review.sock"), session_id=provider.thread_id)), flush=True)
        while True:
            stream, _ = server.accept()
            if capacity.acquire(blocking=False):
                threading.Thread(target=serve_client, args=(stream, review, capacity), daemon=True).start()
            else:
                stream.close()
    finally:
        if server:
            server.close()
            (directory / "review.sock").unlink(missing_ok=True)
        provider.close()


def stop_worker(*_):
    raise KeyboardInterrupt()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    start = actions.add_parser("start", help="Start isolated worker and make the first real model turn")
    start.add_argument("directory", type=Path)
    start.add_argument("--codex", default=shutil.which("codex"))
    start.add_argument("--resume-existing", action="store_true", help="Resume retained session without repeating a turn")
    load = actions.add_parser("load", help="Read the retained review without calling a model")
    load.add_argument("socket", type=Path)
    submit = actions.add_parser("submit", help="Send a structured review and make the correction turn")
    submit.add_argument("socket", type=Path)
    submit.add_argument("request", type=Path)
    args = parser.parse_args()
    if args.action == "start":
        require(bool(args.codex), "An authenticated Codex CLI must be installed")
        signal.signal(signal.SIGTERM, stop_worker)
        serve(args.directory.resolve(), args.codex, args.resume_existing)
    else:
        value = dict(schema=SCHEMA, action="load") if args.action == "load" else json.loads(args.request.read_text())
        print(json.dumps(request(args.socket, value), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (ReviewError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
