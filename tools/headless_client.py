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
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / "zig-out/bin/telar-headless"


def build(root=ROOT):
    """Builds the headless client; tools call it before their first launch."""
    subprocess.run(["zig", "build", "headless"], cwd=root, check=True)


class HeadlessClient:
    def __init__(self, args, env, cwd, size=(140, 40), trace=None, dump=None, log=None, binary=BINARY):
        command = [str(binary), "--size", f"{size[0]}x{size[1]}"]
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
            stdout=subprocess.DEVNULL,
            stderr=self.log,
            env=env,
            cwd=cwd,
            start_new_session=True,
        )

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
