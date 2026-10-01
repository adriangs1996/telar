"""Verify coordinator attribution with a disposable runtime and simulated agent.

Only local temporary repositories and processes are used. No fleet profile,
user configuration or network connection is involved.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(f"Timed out: {description}")
        time.sleep(0.05)


def check(binary):
    with tempfile.TemporaryDirectory(prefix="telar-activity-", dir="/tmp") as temporary:
        root = Path(temporary)
        repo = root / "repo"
        repo.mkdir()
        home = root / "isolated-home"
        home.mkdir()
        socket = root / "runtime.sock"
        environment = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(home),
                           SHELL="/bin/sh", TERM="xterm-256color", LANG="C",
                           XDG_CONFIG_HOME=str(root / "config"),
                           XDG_DATA_HOME=str(root / "data"), TMPDIR=str(root),
                           TELAR_SOCKET=str(socket))

        def command(arguments):
            result = subprocess.run(arguments, env=environment, cwd=repo,
                                    capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (arguments, result.stdout, result.stderr)
            return result.stdout

        for arguments in (["git", "init", "-b", "main"],
                          ["git", "config", "user.name", "Activity test"],
                          ["git", "config", "user.email", "activity@example.invalid"]):
            command(arguments)
        (repo / "README.md").write_text("Activity smoke fixture\n")
        command(["git", "add", "README.md"])
        command(["git", "commit", "-m", "Create fixture"])
        agent = root / "codex"
        quoted_binary = shlex.quote(str(binary))
        agent.write_text(
            "#!/bin/sh\nset -eu\n"
            f"{quoted_binary} agent report-state --current working\n"
            f"{quoted_binary} agent get --current --json > {shlex.quote(str(root / 'source.json'))}\n"
            f"if [ ! -e {shlex.quote(str(root / 'done'))} ]; then\n"
            f"  {quoted_binary} worktree create child --title 'Activity child' --json -- /bin/sh -c 'sleep 30' "
            f"> {shlex.quote(str(root / 'child.json'))}\n"
            f"  touch {shlex.quote(str(root / 'done'))}\nfi\n"
            "while true; do sleep 1; done\n"
        )
        agent.chmod(0o700)
        log = (root / "runtime.log").open("w+")
        process = None

        def start():
            return subprocess.Popen([str(binary), "server", "--no-config", "--socket", str(socket)],
                                    env=environment, cwd=repo, stdout=log, stderr=log)

        def cli(*arguments):
            return command([str(binary), *arguments])

        def stop():
            if process is not None and process.poll() is None:
                try:
                    cli("server", "stop")
                    process.wait(timeout=10)
                except Exception:
                    process.terminate()
                    process.wait(timeout=10)

        try:
            process = start()
            wait_for(socket.exists, "runtime socket")
            cli("workspace", "create", "--directory", str(repo), "--name", "Coordinator",
                "--json", "--", str(agent), "--no-daemon")
            wait_for((root / "done").exists, "verified dispatch")
            source = json.loads((root / "source.json").read_text())
            children = json.loads(cli("worktree", "list", "--json"))
            child = next(row for row in children if row["branch"] == "child")
            expected = {key: source[key] for key in ("session_id", "pane_id", "pane_generation")}
            assert child["coordinator"] == expected, (child, source)
            assert expected["session_id"] != "0" * 32

            # A forwarded reference is attribution, not a local execution identity.
            foreign = "02020202020202020202020202020202:999:123"
            cli("worktree", "create", "forwarded", "--title", "Forwarded task",
                "--coordinator", foreign, "--json", "--", "/bin/sh", "-c", "sleep 30")
            children = json.loads(cli("worktree", "list", "--json"))
            forwarded = next(row for row in children if row["branch"] == "forwarded")
            assert forwarded["coordinator"] == dict(session_id="02" * 16, pane_id=999, pane_generation=123)
            stop()
            process = start()
            wait_for(socket.exists, "restored runtime socket")
            restored = json.loads(cli("worktree", "list", "--json"))
            assert next(row for row in restored if row["branch"] == "child")["coordinator"] == expected
            assert next(row for row in restored if row["branch"] == "forwarded")["coordinator"] == forwarded["coordinator"]
            print("Verified coordinator descent, forwarded attribution and checkpoint restoration")
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            stop()
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/telar")
    arguments = parser.parse_args()
    check(arguments.binary.resolve())


if __name__ == "__main__":
    main()
