#!/usr/bin/env python3
"""Capture the landing page's screenshot from the real Telar window.

Starts an isolated runtime (its own socket and history, no configuration),
opens telar-gui on it, splits the first pane and runs real programs in the
panes, then lets telar-gui save its own window (--screenshot) and exit
(--smoke-ms). Nothing is drawn by hand: agent cards show what the agents
report through their installed integrations. The agent only starts; no prompt
is sent to it. The window shows a neutral machine label instead of the host
name, and the shells a neutral prompt.

    python3 site/scripts/capture.py \\
      --telar .dev/renamed-runtime/telar \\
      --gui .dev/renamed-gui/telar-gui \\
      --out site/public/screens/window.png

The window opens on screen for the duration of the capture. A tiling window
manager may resize it; with AeroSpace, --aerospace floats it so it keeps the
window's default size.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

# A neutral prompt, so the capture shows no host or user name.
ZSHRC = "PROMPT='%F{magenta}❯%f '\nRPROMPT=''\n"


def telar(binary, socket, *words):
    return subprocess.run([str(binary), *words, "--socket", str(socket)], capture_output=True, text=True, check=False)


def wait_for(condition, what, timeout=30.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.25)
    sys.exit(f"capture: timed out waiting for {what}")


def json_rows(result):
    if result.returncode != 0:
        return []
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return []


def at_prompt(cli, socket, pane):
    """True when the pane shows nothing but the neutral shell prompt."""
    text = telar(cli, socket, "pane", "read", str(pane), "--source", "screen").stdout.strip()
    return text == "❯"


def type_into(cli, socket, pane, command):
    """Types a command line into a shell pane, or stops the capture."""
    result = telar(cli, socket, "pane", "send-keys", str(pane), command, "--enter")
    if result.returncode != 0:
        sys.exit(f"capture: pane {pane} refused {command!r}: {result.stderr.strip()}")


def float_window(pid):
    """Floats the window of process `pid` in AeroSpace once it appears."""
    def window_id():
        listed = subprocess.run(["aerospace", "list-windows", "--all", "--format", "%{window-id} %{app-pid}"],
                                capture_output=True, text=True, check=False).stdout.split("\n")
        return next((line.split()[0] for line in listed if line.split()[1:] == [str(pid)]), None)

    subprocess.run(["aerospace", "layout", "--window-id", wait_for(window_id, "the window in AeroSpace"), "floating"], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--telar", type=Path, required=True, help="the telar CLI; telar-runtime must sit beside it")
    parser.add_argument("--gui", type=Path, required=True, help="telar-gui; telar-gui-command must sit beside it")
    parser.add_argument("--out", type=Path, required=True, help="PNG to write")
    parser.add_argument("--cwd", type=Path, default=Path(__file__).resolve().parents[2], help="directory the panes open in")
    parser.add_argument("--agent", default="claude", help="agent command for the first pane (default: claude)")
    parser.add_argument("--editor-file", default="site/components/landing/Weaver.tsx", help="file the editor pane opens, relative to --cwd")
    parser.add_argument("--shell-command", default="just --list", help="command line for the shell pane")
    parser.add_argument("--settle", type=float, default=12.0, help="seconds the programs get before the capture")
    parser.add_argument("--aerospace", action="store_true", help="float the window in AeroSpace so it keeps its default size")
    options = parser.parse_args()

    cli = options.telar.resolve(strict=True)
    cli.with_name("telar-runtime").resolve(strict=True)
    gui = options.gui.resolve(strict=True)
    out = options.out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.unlink(missing_ok=True)

    # A short directory: a Unix socket path must fit in sun_path.
    state = Path(tempfile.mkdtemp(prefix="telar-shot.", dir="/tmp"))
    socket = state / "s"
    zdot = state / "zsh"
    zdot.mkdir()
    (zdot / ".zshrc").write_text(ZSHRC)
    env = dict(os.environ, TELAR_SOCKET=str(socket), TELAR_HISTORY=str(state / "history.db"), ZDOTDIR=str(zdot), SHELL="/bin/zsh")
    # The window reads its machine list from its own config directory; give it
    # a neutral local label. Panes keep the caller's configuration.
    window_config = state / "config" / "telar"
    window_config.mkdir(parents=True, mode=0o700)
    machines = window_config / "machines.json"
    machines.write_text(json.dumps({"version": 1, "local_label": "workstation", "machines": []}))
    machines.chmod(0o600)
    window_env = dict(env, XDG_CONFIG_HOME=str(state / "config"))

    window = None
    try:
        subprocess.run([str(cli), "server", "--background", "--socket", str(socket), "--fresh", "--no-config"], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        wait_for(lambda: telar(cli, socket, "server", "endpoint").returncode == 0, "the runtime")

        # The window lives for the whole capture, then saves itself and exits.
        smoke_ms = int((options.settle + 8) * 1000)
        # Every pane starts the neutral shell; a command passed to the window
        # would become the launch command of every pane it splits.
        window = subprocess.Popen([str(gui), "--socket", str(socket), "--no-config", "--theme", "cybervenom", "--fresh",
                                   "--cwd", str(options.cwd.resolve()), "--smoke-ms", str(smoke_ms), "--screenshot", str(out)],
                                  env=window_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if options.aerospace:
            float_window(window.pid)
        client = wait_for(lambda: json_rows(telar(cli, socket, "client", "list", "--json")), "the window")[0]["id"]
        first = wait_for(lambda: json_rows(telar(cli, socket, "pane", "list", "--json")), "the first pane")[0]["pane_id"]
        time.sleep(1.0)

        # Left: the agent. Right: an editor over a shell.
        telar(cli, socket, "pane", "create", "--client", str(client))
        editor = wait_for(lambda: [row["pane_id"] for row in json_rows(telar(cli, socket, "pane", "list", "--json")) if row["pane_id"] != first], "the second pane")[0]
        wait_for(lambda: telar(cli, socket, "pane", "split", str(editor), "vertical", "--client", str(client)).returncode == 0, "the split")
        shell = wait_for(lambda: [row["pane_id"] for row in json_rows(telar(cli, socket, "pane", "list", "--json")) if row["pane_id"] not in (first, editor)], "the third pane")[0]
        for pane in (first, editor, shell):
            wait_for(lambda: at_prompt(cli, socket, pane), f"the shell prompt in pane {pane}")

        # A person's focused pane refuses typed text, so each pane is typed into
        # while another one has the focus. The agent pane keeps it at the end.
        type_into(cli, socket, first, options.agent)
        type_into(cli, socket, editor, f"nvim --clean {options.editor_file}")
        wait_for(lambda: telar(cli, socket, "pane", "focus", str(first), "--client", str(client)).returncode == 0, "the agent pane's focus")
        type_into(cli, socket, shell, options.shell_command)

        window.wait(timeout=smoke_ms / 1000 + 30)
        if window.returncode != 0 or not out.is_file():
            sys.exit(f"capture: telar-gui exited {window.returncode} without writing {out}")
        print(out)
    finally:
        if window and window.poll() is None:
            window.terminate()
        telar(cli, socket, "server", "stop")
        shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    main()
