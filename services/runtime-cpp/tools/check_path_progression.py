#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_clone_parity import environment_for


def wrapper():
    return '''#!/bin/sh
directory=$PWD
directory_argument=false
for argument in "$@"; do
  if [ "$directory_argument" = true ]; then
    directory=$argument
    directory_argument=false
    continue
  fi
  if [ "$argument" = "-C" ]; then
    directory_argument=true
    continue
  fi
  if [ "$argument" = "ls-files" ]; then
    cd "$directory" || exit 1
    index=0
    while [ "$index" -lt 1024 ]; do
      printf 'src/file_%04d.cpp\\000' "$index"
      index=$((index + 1))
    done
    while [ ! -e ./release ]; do /bin/sleep 0.01; done
    while [ "$index" -lt 2048 ]; do
      printf 'src/file_%04d.cpp\\000' "$index"
      index=$((index + 1))
    done
    exit 0
  fi
done
exec /usr/bin/git "$@"
'''


def check(binary, probe, root):
    fixture = root / "repository"
    fixture.mkdir()
    subprocess.run(["/usr/bin/git", "init", "--quiet", str(fixture)], check=True)
    replacement = root / "replacement"
    replacement.mkdir()
    (replacement / "replacement.txt").write_text("replacement")
    commands = root / "commands"
    commands.mkdir()
    git = commands / "git"
    git.write_text(wrapper())
    git.chmod(0o700)
    environment = environment_for(root)
    environment["PATH"] = str(commands) + os.pathsep + environment.get("PATH", "/usr/bin:/bin")
    socket = root / "runtime.sock"
    dump = root / "results.bin"
    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary), "server", "--socket", str(socket), "--no-config"],
                                  env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Path runtime did not start")
                time.sleep(0.01)
            result = subprocess.run([str(probe), "--controlled", str(socket), str(fixture), str(dump)],
                                    env=environment, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                raise RuntimeError(result.stderr)
            server.wait(timeout=10)
            assert server.returncode == 0
            return json.loads(result.stdout), dump.read_bytes()
        except Exception as error:
            log.flush()
            log.seek(0)
            raise RuntimeError(f"{error}\n{log.read()}") from error
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def main():
    parser = argparse.ArgumentParser(description="Compare path publication, query replacement and cancellation")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {
        name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for name, path in binaries.items()}, "cases": {}}
    try:
        results = []
        for implementation in ("zig", "cpp"):
            with tempfile.TemporaryDirectory(prefix="telar-path-progress-", dir="/tmp") as temporary:
                case, output = check(binaries[implementation], binaries["probe"], Path(temporary))
                report["cases"][implementation] = case
                results.append(output)
                print(implementation, "progressive path checks passed", flush=True)
        assert results[0] == results[1], "Path results differ"
        report["result_sha256"] = hashlib.sha256(results[0]).hexdigest()
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
