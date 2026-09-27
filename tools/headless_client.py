"""Drives `telar-headless`, the client without a window, from tools and tests.

The client reads one command per line on stdin (docs/flows/headless-client.md):
`key NAME`, `text UTF-8`, `resize COLSxROWS`, `mark LABEL` and `quit`. It
writes its trace and dump only when it exits, so nothing here parses output
while the client runs.

    client = HeadlessClient(["--no-config", "--", "cat"], env=env, cwd=root)
    client.text("hello")
    client.key("enter")
    status = client.quit()
"""

import json
import select
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/telar-headless"


def build(root=ROOT):
    """Builds the headless client; tools call it before their first launch."""
    subprocess.run(["zig", "build", "headless"], cwd=root, check=True)


class HeadlessClient:
    def __init__(self, args, env, cwd, size=(140, 40), trace=None, dump=None, log=None, binary=BINARY):
        command = [str(Path(binary).resolve()), "--size", f"{size[0]}x{size[1]}"]
        if trace is not None:
            command += ["--trace", str(trace)]
        if dump is not None:
            command += ["--dump", str(dump)]
        command += [str(arg) for arg in args]
        self.trace_path = trace
        self.dump_path = dump
        self.log = open(log, "w") if log is not None else subprocess.DEVNULL
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            env=env,
            cwd=cwd,
            start_new_session=True,
        )

    def wait_ready(self, timeout=30):
        """Waits until the client admits input: connected, its first tab
        open and startup over."""
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        line = self.process.stdout.readline() if ready else b""
        if line != b"ready\n":
            raise RuntimeError(f"headless client not ready: {line!r}, exit {self.process.poll()}")

    def send(self, *lines):
        for line in lines:
            self.process.stdin.write(line.encode() + b"\n")
        self.process.stdin.flush()

    def key(self, name):
        self.send(f"key {name}")

    def text(self, value):
        self.send(f"text {value}")

    def mark(self, label):
        self.send(f"mark {label}")

    def resize(self, cols, rows):
        self.send(f"resize {cols}x{rows}")

    def running(self):
        return self.process.poll() is None

    def quit(self, timeout=10):
        """Asks the client to leave and waits for its exit status."""
        if self.running():
            try:
                self.send("quit")
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            return self.process.wait(timeout=timeout)
        finally:
            self.close_log()

    def terminate(self, timeout=5):
        if self.running():
            self.process.terminate()
            try:
                self.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=timeout)
        self.close_log()

    def close_log(self):
        if self.log is not subprocess.DEVNULL and not self.log.closed:
            self.log.close()

    def trace(self):
        return json.loads(Path(self.trace_path).read_text())

    def dump(self):
        return json.loads(Path(self.dump_path).read_text())


def echo_latencies(trace, label="text", since=None):
    """Microseconds from each input line named `label` to the first frame
    of the pane it went to, and how many inputs saw no such frame before the
    next input. With `since`, only inputs after the mark of that name count."""
    entries = trace["entries"]
    latencies = []
    timeouts = 0
    counting = since is None
    for index, entry in enumerate(entries):
        if entry["kind"] == "mark" and entry.get("label") == since:
            counting = True
        if not counting or entry["kind"] != "input" or entry.get("label") != label:
            continue
        pane = entry.get("pane")
        for later in entries[index + 1:]:
            if later["kind"] == "input":
                timeouts += 1
                break
            if later["kind"] == "frame" and (pane is None or later.get("pane") == pane):
                latencies.append((later["t_ns"] - entry["t_ns"]) / 1e3)
                break
        else:
            timeouts += 1
    return latencies, timeouts


def last_frame_after(trace, input_index, pane=None):
    """Nanoseconds from the input at `input_index` (counting input entries)
    to the last frame of its pane before the next input, or None."""
    inputs = [i for i, entry in enumerate(trace["entries"]) if entry["kind"] == "input"]
    start = inputs[input_index]
    end = inputs[input_index + 1] if input_index + 1 < len(inputs) else len(trace["entries"])
    entry = trace["entries"][start]
    pane = entry.get("pane") if pane is None else pane
    frames = [later for later in trace["entries"][start + 1:end]
              if later["kind"] == "frame" and (pane is None or later.get("pane") == pane)]
    if not frames:
        return None
    return frames[-1]["t_ns"] - entry["t_ns"]
