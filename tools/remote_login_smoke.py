"""Check remote default login startup with a disposable runtime and local SSH stub.

Run after building telar and telar-headless. No network connection is made;
the stub accepts only the synthetic destination and runs discovery/bridge locally.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from headless_client import HeadlessClient

ROOT = Path(__file__).resolve().parents[1]
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
DESTINATION = "login-test@isolated"


def wait_for(predicate, description):
    deadline = time.monotonic() + 10
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(f"Timed out: {description}")
        time.sleep(0.05)


def environment(root, home, shell, socket):
    return dict(PATH=SYSTEM_PATH, HOME=str(home), ZDOTDIR=str(home),
                TMPDIR=str(root), XDG_CONFIG_HOME=str(root / "config"),
                XDG_DATA_HOME=str(root / "data"), XDG_RUNTIME_DIR=str(root),
                SHELL=shell, TELAR_SOCKET=str(socket), TERM="xterm-256color",
                LANG="C", LC_ALL="C")


def check_case(root, binary, headless, shell, named):
    root.mkdir(mode=0o700)
    home = root / "remote-home"
    home.mkdir()
    local_home = root / "local-home"
    local_home.mkdir()
    socket = root / "runtime.sock"
    report = home / "startup"
    tool_dir = home / "login-bin"
    tool_dir.mkdir()
    tool = tool_dir / "startup-tool"
    tool.write_text("#!/bin/sh\nprintf '%s' profile-tool\n")
    tool.chmod(0o700)
    (home / ".zprofile").write_text(
        f"export TELAR_LOGIN_TEST=profile\nexport PATH={shlex.quote(str(tool_dir))}:$PATH\n"
    )
    (home / ".zshrc").write_text(
        'printf "%s\\n" "$TELAR_LOGIN_TEST" "$(startup-tool)" "$PWD" "$$" '
        f"> {shlex.quote(str(report))}\n"
        "export TELAR_LOGIN_TEST=interactive\n"
    )
    remote_env = environment(root, home, shell, socket)
    stub_dir = root / "stub-bin"
    stub_dir.mkdir()
    (stub_dir / "telar").symlink_to(binary)
    remote_env["PATH"] = f"{stub_dir}:{SYSTEM_PATH}"
    stub = stub_dir / "ssh"
    stub.write_text(
        f"#!{sys.executable}\nimport os, sys\n"
        f"assert sys.argv[-2] == {DESTINATION!r}, sys.argv\n"
        f"environment = {remote_env!r}\n"
        "os.execve('/bin/sh', ['/bin/sh', '-c', sys.argv[-1]], environment)\n"
    )
    stub.chmod(0o700)
    client_env = environment(root, local_home, "/local-only/shell", root / "client.sock")
    client_env["PATH"] = f"{stub_dir}:{SYSTEM_PATH}"
    # A named command must neither read the default shell's dotfiles nor
    # reinterpret literal arguments as shell code.
    literal = "$HOME; literal argument"
    command = ["/bin/sh", "-c",
               'printf "%s\\n" "${TELAR_LOGIN_TEST-unset}" "$1" "$PWD" > "$2"; exec /bin/sh',
               "named-test", literal, str(home / "named")]
    arguments = command if named else []
    client = None
    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary), "server", "--no-config", "--socket", str(socket)],
                                  env=remote_env, cwd=root, stdout=log, stderr=log)
        try:
            wait_for(lambda: socket.exists() or server.poll() is not None, "runtime socket")
            assert server.poll() is None, "runtime exited"

            def launch(label):
                return HeadlessClient(["--no-config", "--remote", DESTINATION, *arguments],
                                      env=client_env, cwd=local_home, binary=headless,
                                      dump=root / f"{label}.json", log=root / f"{label}.log")

            client = launch("first")
            client.wait_ready()
            if named:
                wait_for(lambda: (home / "named").exists(), "named command")
                assert (home / "named").read_text().splitlines() == ["unset", literal, str(home)]
                assert not report.exists(), "named command ran default startup files"
            else:
                wait_for(report.exists, "shell startup")
                lines = report.read_text().splitlines()
                assert lines[:3] == ["profile", "profile-tool", str(home)], lines
                first_pid = int(lines[3])
                os.kill(first_pid, 0)
                assert client.quit() == 0
                client = launch("reconnected")
                client.wait_ready()
                assert report.read_text().splitlines() == lines, "reconnect launched another shell"
                # Probe retained interactive state and PID through the same pane.
                retained = home / "retained"
                client.text('printf "%s\\n" "$TELAR_LOGIN_TEST" "$$" > ' + shlex.quote(str(retained)))
                client.key("enter")
                wait_for(retained.exists, "retained shell state")
                assert retained.read_text().splitlines() == ["interactive", str(first_pid)]
            assert client.quit() == 0
            return "named command unchanged" if named else "login before interactive; home, PID and state retained"
        except Exception:
            for name in ("first.log", "reconnected.log", "server.log"):
                path = root / name
                if path.exists():
                    print(f"{path.name}:\n{path.read_text()[-4000:]}", file=sys.stderr)
            raise
        finally:
            if client is not None:
                client.terminate()
            if server.poll() is None:
                try:
                    subprocess.run([str(binary), "server", "stop", "--socket", str(socket)],
                                   env=remote_env, capture_output=True, timeout=5, check=True)
                    server.wait(timeout=5)
                except (subprocess.SubprocessError, OSError):
                    server.terminate()
                    server.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary-dir", type=Path, default=ROOT / "zig-out/bin")
    options = parser.parse_args()
    shell = shutil.which("zsh", path=SYSTEM_PATH)
    if shell is None:
        parser.error("zsh is required for the synthetic .zprofile/.zshrc regression")
    binaries = options.binary_dir.resolve()
    with tempfile.TemporaryDirectory(prefix="telar-login-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        results = [check_case(root / name, binaries / "telar", binaries / "telar-headless", shell, named)
                   for name, named in [("default", False), ("explicit", True)]]
    print(json.dumps(dict(passed=results), indent=2))


if __name__ == "__main__":
    main()
