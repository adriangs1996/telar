#!/usr/bin/env python3
"""Opt-in CLI integration against an isolated real runtime and the headless client.

Run after `zig build` and `zig build headless`: python3 tools/test_cli_live.py
All sockets, configuration, plugins and persistent data live in temporary paths.
"""

import json
import os
import pty
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from headless_client import HeadlessClient

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("TELAR_TEST_BINARY", ROOT / "zig-out/bin/telar"))


class LiveCliTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="telar-live-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.endpoint = self.root / "runtime.sock"
        self.environment = dict(
            os.environ,
            XDG_DATA_HOME=str(self.root / "data"),
            XDG_CONFIG_HOME=str(self.root / "config"),
            SHELL="/bin/sh",
            TERM="xterm-256color",
            TELAR_SOCKET=str(self.endpoint),
        )
        self.server_output = (self.root / "server.log").open("w+")
        self.addCleanup(self.server_output.close)
        self.server = subprocess.Popen(
            [str(BINARY), "server", "--no-config", "--socket", str(self.endpoint)],
            cwd=self.root, env=self.environment,
            stdout=self.server_output, stderr=self.server_output,
        )
        self.addCleanup(self.stop_server)
        deadline = time.monotonic() + 8
        while not self.endpoint.exists() and self.server.poll() is None:
            self.assertLess(time.monotonic(), deadline, "runtime did not bind")
            time.sleep(0.05)
        self.assertIsNone(self.server.poll(), "runtime exited during startup")
        self.assertTrue(self.call("runtime", "status")["running"])

    def stop_server(self):
        if self.server.poll() is None:
            try:
                subprocess.run(
                    [str(BINARY), "server", "stop", "--socket", str(self.endpoint)],
                    env=self.environment, capture_output=True, timeout=5,
                )
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.terminate()
                self.server.wait(timeout=5)
        if self.server.returncode:
            self.server_output.seek(0)
            print(self.server_output.read())

    def call(self, *arguments, json_output=True, client=None):
        command = [str(BINARY), *map(str, arguments), "--socket", str(self.endpoint)]
        if client is not None:
            command += ["--client", str(client)]
        if json_output:
            command += ["--json"]
        result = subprocess.run(
            command, cwd=self.root, env=self.environment,
            capture_output=True, text=True, timeout=12,
        )
        self.assertEqual(result.returncode, 0, (arguments, result.stderr, result.stdout))
        return json.loads(result.stdout) if json_output else result.stdout

    def eventually(self, predicate, description):
        deadline = time.monotonic() + 8
        while not predicate():
            self.assertLess(time.monotonic(), deadline, description)
            time.sleep(0.2)

    def test_runtime_topology_text_search_and_logs(self):
        self.call("runtime", "metrics")
        self.call("proxy", "watch", "--count", 1)
        self.assertEqual(self.call("workspace", "list"), [])
        self.assertEqual(self.call("client", "list"), [])
        self.assertEqual(self.call("pane", "list"), [])
        workspace = self.call(
            "workspace", "create", "--directory", self.root, "--name", "CLI smoke"
        )["workspace_id"]
        self.call("workspace", "get", workspace)
        self.assertEqual(
            self.call("workspace", "rename", workspace, "Renamed smoke")["name"],
            "Renamed smoke",
        )
        tabs = self.call("tab", "list", "--workspace", workspace)
        self.assertEqual(len(tabs), 1)
        tab = tabs[0]["tab_id"]
        self.call("tab", "get", tab, "--workspace", workspace)
        self.call("tab", "rename", tab, "smoke shell", "--workspace", workspace)
        panes = self.call("pane", "list", "--workspace", workspace, "--tab", tab)
        self.assertEqual(len(panes), 1)
        pane = panes[0]["pane_id"]
        self.call("pane", "get", pane, "--workspace", workspace, "--tab", tab)
        self.call(
            "pane", "send-keys", pane, "printf 'telar_cli_smoke_token\\n'", "--enter",
            json_output=False,
        )
        self.eventually(
            lambda: "telar_cli_smoke_token" in self.call("pane", "read", pane, json_output=False),
            "shell output was not retained",
        )
        self.assertTrue(self.call("pane", "search", pane, "telar_cli_smoke_token")["matches"])
        self.call("pane", "watch", pane, "--workspace", workspace, "--tab", tab, "--count", 1)
        self.assertTrue(self.call("diagnostics", "logs", "--component", "runtime", "--lines", 2))
        self.call("tab", "close", tab, "--workspace", workspace)
        self.assertEqual(self.call("workspace", "list"), [])

    def git(self, *arguments, cwd):
        identity = ["-c", "user.name=telar", "-c", "user.email=telar@localhost", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", *identity, *arguments], cwd=cwd, check=True, capture_output=True, timeout=12)

    def branches(self, repository):
        result = subprocess.run(
            ["git", "branch", "--format=%(refname:short)"], cwd=repository,
            check=True, capture_output=True, text=True, timeout=12,
        )
        return result.stdout.split()

    def remove_worktree(self, branch, answer=None):
        """`worktree remove --delete-branch`, on a terminal that types `answer` when given."""
        command = [str(BINARY), "worktree", "remove", branch, "--delete-branch", "--socket", str(self.endpoint)]
        if answer is None:
            return subprocess.run(
                command, cwd=self.root, env=self.environment, stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=12,
            )
        controller, terminal = pty.openpty()
        try:
            os.write(controller, answer.encode())
            return subprocess.run(
                command, cwd=self.root, env=self.environment, stdin=terminal,
                capture_output=True, text=True, timeout=12,
            )
        finally:
            os.close(terminal)
            os.close(controller)

    def test_worktree_remove_deletes_a_merged_branch_alone_and_an_unmerged_one_on_a_yes(self):
        repository = self.root / "repo"
        repository.mkdir()
        self.git("init", "-q", "-b", "main", cwd=repository)
        self.git("commit", "-q", "--allow-empty", "-m", "one", cwd=repository)
        self.call("workspace", "create", "--directory", repository, "--name", "repo")
        for branch in ("landed", "kept", "confirmed"):
            self.call("worktree", "create", branch, "--title", branch, "--workspace", repository)
            self.git("commit", "-q", "--allow-empty", "-m", branch, cwd=self.root / "repo-worktrees" / branch)
        self.git("merge", "-q", "--ff-only", "landed", cwd=repository)

        merged = self.remove_worktree("landed")
        self.assertEqual(merged.returncode, 0, merged.stderr)
        self.assertNotIn("landed", self.branches(repository))

        unattended = self.remove_worktree("kept")
        self.assertNotEqual(unattended.returncode, 0)
        self.assertIn("confirm it at a terminal", unattended.stderr)
        self.assertIn("kept", self.branches(repository))
        self.assertTrue((self.root / "repo-worktrees" / "kept").exists())

        confirmed = self.remove_worktree("confirmed", answer="y\n")
        self.assertEqual(confirmed.returncode, 0, confirmed.stderr)
        self.assertNotIn("confirmed", self.branches(repository))
        self.assertFalse((self.root / "repo-worktrees" / "confirmed").exists())

    def start_client(self):
        shutil.copytree(ROOT / "examples/plugins/sample", self.root / "plugin")
        configuration = self.root / "config.lua"
        configuration.write_text(
            'local t = require("telar")\n'
            'return t.config({api_version=2, '
            'plugins={t.plugin({path="plugin", enabled=false})}})\n'
        )
        client = HeadlessClient(
            ["--config", configuration, "--", "/bin/sh"], env=self.environment, cwd=self.root,
            size=(140, 40), log=self.root / "client.log", binary=BINARY.with_name("telar-headless"),
        )
        self.addCleanup(client.terminate)
        client.wait_ready()
        self.eventually(lambda: bool(self.call("client", "list")), (self.root / "client.log").read_text()[-4000:])
        return self.call("client", "list")[0]["id"]

    def test_routed_layout_configuration_and_plugin_lifecycle(self):
        client = self.start_client()

        def ui(*args):
            return self.call(*args, client=client)

        ui("sidebar", "hide")
        self.assertFalse(ui("sidebar", "get")["visible"])
        ui("sidebar", "show")
        self.assertTrue(ui("sidebar", "get")["visible"])
        ui("sidebar", "resize", 24)
        ui("workspace-list", "collapse")
        ui("workspace-list", "expand")
        generation = ui("config", "show")["generation"]
        ui("config", "reload")
        self.eventually(
            lambda: ui("config", "show")["generation"] > generation,
            "forced reload was not adopted",
        )
        self.assertFalse(ui("plugin", "list")[0]["enabled"])
        ui("plugin", "get", "plugin")
        ui("plugin", "enable", "plugin")
        self.eventually(lambda: ui("plugin", "list")[0]["enabled"], "enable was not adopted")
        plugin = ui("plugin", "get", "dev.telar.sample")
        self.assertEqual(plugin["actions"], ["toggle"])
        visible = ui("sidebar", "get")["visible"]
        ui("plugin", "run", "dev.telar.sample", "toggle")
        self.eventually(
            lambda: ui("sidebar", "get")["visible"] != visible,
            "worker action was not applied",
        )
        ui("plugin", "disable", "dev.telar.sample")
        self.eventually(lambda: not ui("plugin", "list")[0]["enabled"], "disable was not adopted")
        panes = self.call("pane", "list")
        self.assertTrue(panes)
        pane = panes[0]["pane_id"]
        ui("pane", "focus", pane)
        ui("pane", "fullscreen", pane)
        ui("pane", "fullscreen", pane)
        layout = ui("layout", "get")
        ui("layout", "apply", layout["data"])
        ui("pane", "split", pane, "vertical")
        self.eventually(lambda: len(self.call("pane", "list")) == 2, "split was not applied")
        split = self.call("pane", "list")
        ui("pane", "close", split[-1]["pane_id"])
        self.eventually(lambda: len(self.call("pane", "list")) == 1, "close was not applied")
        self.call("client", "detach", client)


if __name__ == "__main__":
    unittest.main()
