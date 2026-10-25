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


def prepare(root, worktree=False):
    repository = root / "repository"
    repository.mkdir()
    environment = environment_for(root)
    environment.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                        "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+00:00",
                        "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+00:00"})
    def git(*arguments):
        return subprocess.check_output(["/usr/bin/git", "-C", str(repository),
                                        "-c", "user.name=Runtime Fixture", "-c", "user.email=fixture@example.invalid",
                                        "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *arguments],
                                       env=environment, text=True)
    git("init", "--quiet", "--initial-branch=main", "--template=")
    (repository / "file.txt").write_text("initial\n")
    git("add", "file.txt")
    git("commit", "--quiet", "-m", "Initial fixture")
    (root / "commit").write_text(git("rev-parse", "HEAD"))
    if worktree:
        git("worktree", "add", "--quiet", "-b", "feature", str(root / "linked"))
        (root / "linked" / "nested").mkdir()
    commands = root / "commands"
    commands.mkdir()
    wrapper = commands / "git"
    wrapper.write_text('''#!/bin/sh
for argument in "$@"; do
  if [ "$argument" = status ]; then
    mode=$(/bin/cat "$WORKSPACE_GIT_FIXTURE/mode")
    if [ "$mode" = failure ]; then
      printf '?? partial-output-before-failure\\n'
      exit 1
    fi
  fi
done
exec /usr/bin/git "$@"
''')
    wrapper.chmod(0o700)
    (root / "mode").write_text("normal")
    environment["PATH"] = str(commands) + os.pathsep + environment.get("PATH", "/usr/bin:/bin")
    environment["WORKSPACE_GIT_FIXTURE"] = str(root)
    return environment


def check(binary, probe, root, worktree=False):
    environment = prepare(root, worktree)
    socket = root / "runtime.sock"
    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary), "server", "--socket", str(socket), "--no-config"],
                                  env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Workspace Git runtime did not start")
                time.sleep(0.01)
            output = root / "results.bin"
            result = subprocess.run([str(probe), str(socket), str(root), str(output)],
                                    env=environment, capture_output=True, text=True, timeout=90)
            if result.returncode != 0:
                raise RuntimeError(f"Probe exited {result.returncode}: {result.stderr.strip()} {result.stdout.strip()}")
            server.wait(timeout=10)
            assert server.returncode == 0
            return json.loads(result.stdout), output.read_bytes()
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
    parser = argparse.ArgumentParser(description="Compare workspace Git observations and failure retention")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--worktree-detection", action="store_true")
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {
        name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for name, path in binaries.items()}, "cases": {},
        "worktree_detection": arguments.worktree_detection,
        "normalization": "IDs, paths and revisions are normalized. Workspace branch/dirty or discovered worktree fields match exactly."}
    try:
        outputs = []
        for implementation in ("zig", "cpp"):
            with tempfile.TemporaryDirectory(prefix="telar-workspace-git-", dir="/tmp") as temporary:
                case, output = check(binaries[implementation], binaries["probe"], Path(temporary), arguments.worktree_detection)
                report["cases"][implementation] = case
                outputs.append(output)
                print(implementation, "workspace Git checks passed", flush=True)
        assert outputs[0] == outputs[1], "Workspace Git protocol differs"
        report["result_sha256"] = hashlib.sha256(outputs[0]).hexdigest()
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
