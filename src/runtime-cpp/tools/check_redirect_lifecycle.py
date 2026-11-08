#!/usr/bin/env python3
"""Verify concurrent native helpers, exclusive ownership and recovery after process crashes."""

import argparse
import os
import pathlib
import shlex
import signal
import subprocess
import tempfile
import time

from check_redirect import Origin, exchange, loopback_status


class Session:
    def __init__(self, binary, root, origin):
        self.binary, self.root, self.origin = binary, root, origin
        root.mkdir(mode=0o700)
        self.endpoint = root / "runtime.sock"
        self.runtime = None
        self.helper = None
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={enabled=true,transparent_redirect=true,ca_dir='ca'}}}\n")
        self.runtime_log = (root / "runtime.log").open("w")
        self.helper_log = (root / "helper.log").open("w")
        try:
            self.runtime = subprocess.Popen([str(binary), "--socket", str(self.endpoint), "--config", str(config), "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=self.runtime_log, stderr=self.runtime_log)
            deadline = time.monotonic() + 10
            while not pathlib.Path(str(self.endpoint) + ".redirect").exists():
                if self.runtime.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Lifecycle runtime did not start")
                time.sleep(0.01)
            self.command = [str(binary), "traffic", "redirect", "--socket", str(self.endpoint), "--target", f"127.0.0.1:{origin.port}"]
            self.start_helper()
        except Exception:
            self.close()
            raise

    def start_helper(self):
        self.helper_log.seek(0)
        self.helper_log.truncate()
        self.helper = subprocess.Popen(["sudo", "-n", *self.command], stdin=subprocess.DEVNULL, stdout=self.helper_log, stderr=self.helper_log)
        deadline = time.monotonic() + 15
        while "telar redirect: active" not in (self.root / "helper.log").read_text():
            if self.helper.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Lifecycle helper did not activate: " + (self.root / "helper.log").read_text())
            time.sleep(0.02)

    def crash_helper(self):
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,uid=,command="], capture_output=True, text=True, check=True).stdout
        matches = []
        for line in listing.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and fields[1] == "0" and shlex.split(fields[2]) == self.command:
                matches.append(int(fields[0]))
        if len(matches) != 1:
            raise RuntimeError("Cannot identify the exact owned root helper to terminate")
        subprocess.run(["sudo", "-n", "/bin/kill", "-KILL", str(matches[0])], check=True, timeout=5)
        self.helper.wait(timeout=5)
        self.helper = None

    def close(self):
        errors = []
        if self.runtime is not None and self.runtime.poll() is None:
            self.runtime.terminate()
            try:
                self.runtime.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.runtime.kill()
                self.runtime.wait(timeout=5)
                errors.append("Runtime shutdown required SIGKILL")
        if self.helper is not None:
            try:
                status = self.helper.wait(timeout=20)
                if status != 0:
                    errors.append(f"Helper exited with {status}")
            except subprocess.TimeoutExpired:
                errors.append("Helper survived runtime shutdown")
        result = subprocess.run(["sudo", "-n", str(self.binary), "traffic", "redirect-cleanup", "--socket", str(self.endpoint)], capture_output=True, text=True, timeout=25)
        if result.returncode:
            errors.append(result.stdout + result.stderr)
        self.runtime_log.close()
        self.helper_log.close()
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    options = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Run as your account; only helpers are elevated")
    subprocess.run(["sudo", "-v"], check=True)
    binary = options.runtime.resolve()
    root = pathlib.Path(tempfile.mkdtemp(prefix="tlr-lifecycle-", dir="/tmp")).resolve()
    origins, sessions, errors = [], [], []
    success = False
    original_skip = loopback_status(root, "before")
    try:
        for index in range(2):
            origins.append(Origin("127.0.0.1"))
            sessions.append(Session(binary, root / str(index), origins[-1]))
        for origin in origins:
            exchange(origin, True)
        duplicate = subprocess.run(["sudo", "-n", *sessions[0].command], capture_output=True, text=True, timeout=10)
        if duplicate.returncode == 0:
            raise RuntimeError("Two helpers acquired the same endpoint")
        sessions[0].crash_helper()
        sessions[0].start_helper()
        exchange(origins[0], True)
        exchange(origins[1], True)
        print("Concurrent helpers, exclusive endpoint ownership and helper crash recovery verified", flush=True)
        sessions[0].runtime.kill()
        sessions[0].runtime.wait(timeout=5)
        if sessions[0].helper.wait(timeout=20) != 0:
            raise RuntimeError("Helper did not clean up after runtime SIGKILL")
        exchange(origins[0], False)
        exchange(origins[1], True)
        if loopback_status(root, "one-survivor"):
            raise RuntimeError("Loopback filtering was restored while another helper still needed it")
        print("Runtime crash cleanup and surviving helper lease verified", flush=True)
        success = True
    finally:
        for session in reversed(sessions):
            try:
                errors.extend(session.close())
            except Exception as error:
                errors.append(str(error))
        try:
            if loopback_status(root, "after") != original_skip:
                errors.append("Original PF loopback status was not restored")
        except Exception as error:
            errors.append(str(error))
        for origin in origins:
            origin.close()
        if errors:
            (root / "cleanup-errors.log").write_text("\n".join(errors))
            success = False
        if not success:
            print(f"Lifecycle diagnostics preserved at {root}")
        else:
            import shutil
            shutil.rmtree(root)
    if errors:
        raise RuntimeError("; ".join(errors))
    print("Final cleanup and PF loopback restoration verified")


if __name__ == "__main__":
    main()
