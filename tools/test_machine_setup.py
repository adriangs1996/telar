#!/usr/bin/env python3
"""`telar machine setup` end to end, against a machine simulated on this one.

A fake `ssh` first on the PATH runs every remote command here with `/bin/sh`,
in the simulated machine's home, PATH and runtime directory, the way sshd
runs it through a login shell. So the probe, the installer, `receive-config`,
the runtime setup starts, its login panes and `dispatch-argv` are all real;
only the network and the agents are not. Fake agents answer their login and
status commands, and nothing is downloaded (`--binary` installs this build).

`FAKE_SSH_FAIL` makes the fake fail every call whose command or script holds
that text: `FAKE_SSH_MODE=exit255` the way OpenSSH fails a connection,
`toolong` by printing more than a script may, `malformed` with invalid JSON,
or `removed` by running a close twice to simulate a child-exit cleanup race.

Run after `zig build`: python3 tools/test_machine_setup.py
Everything lives in a temporary directory under /tmp and is removed after.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("TELAR_TEST_BINARY", ROOT / "zig-out/bin/telar"))
DESTINATION = "dev@fakebox"
LABEL = "fakebox"
# Every secret the local configuration plants starts with this.
PLANTED = "PLANTED"

FAKE_SSH = r"""#!/bin/sh
# ssh stand-in: runs the remote command here as the simulated machine.
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
destination=$1
shift
[ "$destination" = dev@fakebox ] || exit 255
command=$*
input=$(mktemp "$FAKE_SSH_ROOT/stdin.XXXXXX")
cat > "$input"
for operation in "'pane' 'read'" "'tab' 'get'" "'tab' 'close'"; do
    if grep -qF -- "$operation" "$input"; then
        printf '%s\n' "$operation" >> "$FAKE_SSH_ROOT/calls"
    fi
done
if [ -n "${FAKE_SSH_FAIL:-}" ]; then
    if printf '%s\n' "$command" | grep -qF -- "$FAKE_SSH_FAIL" || grep -qF -- "$FAKE_SSH_FAIL" "$input"; then
        if [ "${FAKE_SSH_MODE:-exit255}" = removed ]; then
            env -i HOME="$FAKE_REMOTE_HOME" TMPDIR="$FAKE_REMOTE_TMP" USER="$USER" SHELL=/bin/sh \
                PATH="$FAKE_REMOTE_HOME/.local/bin:/usr/bin:/bin" /bin/sh -c "$command" < "$input" >/dev/null 2>&1
        elif [ "${FAKE_SSH_MODE:-exit255}" = malformed ]; then
            rm -f "$input"
            echo '{}'
            exit 0
        elif [ "${FAKE_SSH_MODE:-exit255}" = toolong ]; then
            rm -f "$input"
            head -c 300000 /dev/zero | tr '\0' x
            exit 0
        else
            rm -f "$input"
            echo "ssh: connect to host $destination port 22: Operation timed out" >&2
            exit 255
        fi
    fi
fi
env -i HOME="$FAKE_REMOTE_HOME" TMPDIR="$FAKE_REMOTE_TMP" USER="$USER" LOGNAME="$USER" SHELL=/bin/sh \
    PATH="$FAKE_REMOTE_HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh -c "$command" < "$input"
status=$?
rm -f "$input"
exit $status
"""

# The simulated machine's Codex: logged in once `.codex-fake-auth` exists;
# its device login prints what the real one prints, then waits.
FAKE_CODEX = r"""#!/bin/sh
case "$1 ${2:-}" in
    "login status") [ -f "$HOME/.codex-fake-auth" ] ;;
    "login --device-auth")
        mode=$(cat "$HOME/.codex-fake-mode" 2>/dev/null)
        case "$mode" in
            fail-before) echo "Synthetic login failure"; exit 7 ;;
            zero-without-auth) exit 0 ;;
            success-before) touch "$HOME/.codex-fake-auth"; exit 0 ;;
        esac
        echo "Welcome to Codex"
        echo "1. Open this link in your browser and sign in to your account"
        echo "   https://auth.openai.com/codex/device"
        echo "2. Enter this one-time code (expires in 15 minutes)"
        echo "   FAKE-1234"
        case "$mode" in
            fail-after) sleep 2; exit 9 ;;
            success-after) sleep 2; touch "$HOME/.codex-fake-auth"; exit 0 ;;
            released) while [ ! -f "$HOME/.codex-release" ]; do sleep 0.1; done; exit 8 ;;
            *) exec sleep 600 ;;
        esac ;;
    *) echo "codex-fake 0.0.0" ;;
esac
"""

FAKE_CLAUDE = r"""#!/bin/sh
case "$1 ${2:-}" in
    "auth status") [ ! -f "$HOME/.claude-fake-fail" ] ;;
    "auth login") echo "Synthetic login failure"; exit 6 ;;
    *) echo "claude-fake 0.0.0" ;;
esac
"""


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


class MachineSetupTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(BINARY.is_file(), f"build {BINARY} first: zig build")
        self.directory = tempfile.TemporaryDirectory(prefix="tms-", dir="/tmp")
        self.root = Path(os.path.realpath(self.directory.name))
        self.addCleanup(self.directory.cleanup)
        self.local = self.root / "l"
        self.remote = self.root / "r"
        self.bin = self.root / "bin"
        for directory in (self.local, self.remote, self.bin, self.root / "lt", self.root / "rt"):
            directory.mkdir(mode=0o700)

        write(self.bin / "ssh", FAKE_SSH, 0o755)
        write(self.bin / "codex", "#!/bin/sh\n", 0o755)
        write(self.bin / "claude", "#!/bin/sh\n", 0o755)
        write(self.remote / ".local/bin/codex", FAKE_CODEX, 0o755)
        write(self.remote / ".local/bin/claude", FAKE_CLAUDE, 0o755)
        self.plant_configuration()

        user = os.environ.get("USER", "telar")
        self.environment = {
            "HOME": str(self.local),
            "TMPDIR": str(self.root / "lt"),
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "USER": user,
            "LOGNAME": user,
            "SHELL": "/bin/sh",
            "LANG": "C.UTF-8",
            "FAKE_SSH_ROOT": str(self.root),
            "FAKE_REMOTE_HOME": str(self.remote),
            "FAKE_REMOTE_TMP": str(self.root / "rt"),
        }
        self.remote_environment = {
            "HOME": str(self.remote),
            "TMPDIR": str(self.root / "rt"),
            "PATH": f"{self.remote}/.local/bin:/usr/bin:/bin",
            "USER": user,
            "SHELL": "/bin/sh",
        }
        self.addCleanup(self.stop_remote_runtime)

    def plant_configuration(self):
        local = self.local
        write(local / ".claude/CLAUDE.md", "# Rules\n")
        write(local / ".claude/settings.json", '{"model": "opus", "env": {"KEY": "PLANTED-env"}}\n')
        write(local / ".claude.json", '{"oauthAccount": "PLANTED-oauth"}\n')
        (local / ".claude/skills").mkdir(parents=True)
        (local / ".claude/skills/notes.json").symlink_to(local / ".claude.json")
        write(local / ".claude/skills/review/SKILL.md", "# Review\n")
        write(
            local / ".claude/agents/github.md",
            "---\nname: github\nmcpServers:\n  github:\n    env:\n      GITHUB_TOKEN: PLANTED-frontmatter\n---\n",
        )
        write(
            local / ".codex/config.toml",
            'model = "gpt-5"\n[model_providers.x.http_headers]\nAuthorization = "Bearer PLANTED-header"\n',
        )

    def stop_remote_runtime(self):
        for telar in (self.remote / ".local/share/telar/versions").glob("*/telar"):
            subprocess.run([str(telar), "server", "stop"], env=self.remote_environment, capture_output=True, timeout=20)

        # `server stop` returns once the runtime agreed; it still closes its
        # panes and history before its socket goes.
        deadline = time.monotonic() + 20
        while list((self.root / "rt").glob("telar-*/*.sock")) and time.monotonic() < deadline:
            time.sleep(0.1)

    def telar(self, *arguments, environment=None, timeout=240):
        return subprocess.run(
            [str(BINARY), *arguments],
            env=environment or self.environment,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            timeout=timeout,
        )

    def setup(self, *arguments, fail=None, mode="exit255"):
        environment = dict(self.environment)
        if fail is not None:
            environment["FAKE_SSH_FAIL"] = fail
            environment["FAKE_SSH_MODE"] = mode

        result = self.telar("machine", "setup", DESTINATION, "--label", LABEL, "--binary", str(BINARY), *arguments, environment=environment)
        return result

    def report(self, result):
        lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
        self.assertEqual(1, len(lines), f"one JSON report expected:\n{result.stdout}\n{result.stderr}")
        report = json.loads(lines[0])
        return report, {step["step"]: step["status"] for step in report["steps"]}

    def remote_telar(self):
        found = list((self.remote / ".local/share/telar/versions").glob("*/telar"))
        self.assertEqual(1, len(found))
        return found[0]

    def remote_command(self, *arguments):
        result = subprocess.run(
            [str(self.remote_telar()), *arguments], env=self.remote_environment,
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(result.stdout)

    def login_record(self, agent="codex"):
        return self.remote / ".local/state/telar/setup-logins" / agent

    def calls(self, operation):
        path = self.root / "calls"
        return path.read_text().splitlines().count(operation) if path.exists() else 0

    def interactive_setup(self):
        master, slave = os.openpty()
        try:
            return subprocess.run(
                [str(BINARY), "machine", "setup", DESTINATION, "--label", LABEL, "--binary", str(BINARY)],
                env=self.environment, stdin=slave, capture_output=True, text=True, timeout=30,
            )
        finally:
            os.close(slave)
            os.close(master)

    def assert_no_lifecycle_noise(self, result):
        for diagnostic in ("workspace not found", "tab not found", "the command exited"):
            self.assertNotIn(diagnostic, result.stderr)

    def remote_workspaces(self):
        listed = subprocess.run(
            [str(self.remote_telar()), "workspace", "list", "--json"],
            env=self.remote_environment, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(0, listed.returncode, listed.stderr)
        return [(workspace["workspace_id"], workspace["name"]) for workspace in json.loads(listed.stdout)]

    def assert_nothing_planted_there(self):
        for path in self.remote.rglob("*"):
            if path.is_file() and not path.is_symlink() and "versions" not in path.parts and path.stat().st_size < 1 << 20:
                self.assertNotIn(PLANTED, path.read_text(errors="replace"), f"{path} holds a planted secret")

    def test_setup_installs_syncs_and_changes_nothing_the_second_time(self):
        first = self.setup("--json")
        report, steps = self.report(first)
        self.assertEqual(0, first.returncode, first.stdout + first.stderr)
        self.assertEqual("changed", steps["telar"])
        self.assertEqual("changed", steps["profile"])
        self.assertEqual("pending", steps["logins"], report)
        self.assertEqual("ok", steps["check"], report)
        self.assertFalse(report["ready"])
        self.assertTrue(report["pending"])

        self.assertTrue((self.remote / ".claude/CLAUDE.md").is_file())
        self.assertTrue((self.remote / ".claude/skills/review/SKILL.md").is_file())
        self.assertIn('model = "gpt-5"', (self.remote / ".codex/config.toml").read_text())
        self.assertFalse((self.remote / ".claude/agents/github.md").exists())
        self.assertFalse((self.remote / ".claude.json").exists())
        self.assert_nothing_planted_there()
        self.assertEqual(os.readlink(self.remote / ".local/bin/telar"), str(self.remote_telar()))
        self.assertEqual(["Log in to Codex"], [name for _, name in self.remote_workspaces()])

        # The person finishes the Codex login in the browser.
        (self.remote / ".codex-fake-auth").touch()
        second = self.setup("--json")
        report, steps = self.report(second)
        self.assertEqual(0, second.returncode, second.stdout + second.stderr)
        self.assertEqual({"ok"}, set(steps.values()), report)
        self.assertTrue(report["ready"])
        self.assertFalse(report["changed"])
        self.assertEqual([], self.remote_workspaces())
        self.assertFalse(self.login_record().exists())

        third = self.setup()
        self.assertEqual(0, third.returncode, third.stdout + third.stderr)
        self.assertTrue(third.stdout.rstrip().endswith(f"{LABEL} was already set up; nothing changed."), third.stdout)

    def test_pending_login_resumes_the_same_pane(self):
        self.assertEqual("pending", self.report(self.setup("--json"))[1]["logins"])
        record = self.login_record().read_text()
        workspaces = self.remote_workspaces()
        self.assertEqual("pending", self.report(self.setup("--json"))[1]["logins"])
        self.assertEqual(record, self.login_record().read_text())
        self.assertEqual(workspaces, self.remote_workspaces())

    def test_missing_workspace_record_is_forgotten_without_querying_its_tabs(self):
        self.assertEqual(0, self.setup("--skip", "login").returncode)
        (self.remote / ".codex-fake-auth").touch()
        write(self.login_record(), "999999 888888 777777\n")
        result = self.setup("--json")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("ok", self.report(result)[1]["logins"])
        self.assertFalse(self.login_record().exists())
        self.assertEqual(0, self.calls("'tab' 'get'"))
        self.assertEqual(0, self.calls("'tab' 'close'"))
        self.assert_no_lifecycle_noise(result)

    def test_missing_tab_record_keeps_the_workspace_and_forgets_the_record(self):
        self.assertEqual(0, self.setup("--skip", "login").returncode)
        created = self.remote_command("workspace", "create", "--directory", str(self.remote), "--name", "Log in to Codex", "--json")
        write(self.login_record(), f"{created['workspace_id']} 999999 {created['pane_id']}\n")
        (self.remote / ".codex-fake-auth").touch()
        result = self.setup("--json")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertFalse(self.login_record().exists())
        self.assertEqual([(created["workspace_id"], "Log in to Codex")], self.remote_workspaces())
        self.assertEqual(1, self.calls("'tab' 'get'"))
        self.assertEqual(0, self.calls("'tab' 'close'"))
        self.assert_no_lifecycle_noise(result)

    def test_stale_ids_never_close_a_different_workspace_or_pane(self):
        self.assertEqual(0, self.setup("--skip", "login").returncode)
        (self.remote / ".codex-fake-auth").touch()
        for name, wrong_pane in (("notes", False), ("Log in to Codex", True)):
            with self.subTest(name=name):
                created = self.remote_command("workspace", "create", "--directory", str(self.remote), "--name", name, "--json")
                pane_id = 999999 if wrong_pane else created["pane_id"]
                write(self.login_record(), f"{created['workspace_id']} {created['tab_id']} {pane_id}\n")
                result = self.setup("--json")
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn((created["workspace_id"], name), self.remote_workspaces())
                self.assertFalse(self.login_record().exists())
                self.assertEqual(0, self.calls("'tab' 'close'"))
                self.assert_no_lifecycle_noise(result)

    def test_cleanup_tolerates_the_tab_disappearing_after_the_ownership_check(self):
        self.assertEqual("pending", self.report(self.setup("--json"))[1]["logins"])
        (self.remote / ".codex-fake-auth").touch()
        result = self.setup("--json", fail="'tab' 'close'", mode="removed")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("ok", self.report(result)[1]["logins"])
        self.assertFalse(self.login_record().exists())
        self.assertEqual([], self.remote_workspaces())
        self.assert_no_lifecycle_noise(result)

    def test_failed_login_before_a_link_reports_once_and_continues_to_the_next_agent(self):
        (self.remote / ".claude-fake-fail").touch()
        start = time.monotonic()
        result = self.setup("--json")
        report, steps = self.report(result)
        self.assertLess(time.monotonic() - start, 30)
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual("failed", steps["logins"])
        self.assertEqual("ok", steps["check"])
        notes = next(step["notes"] for step in report["steps"] if step["step"] == "logins")
        self.assertEqual(1, sum("login command exited with 6" in note for note in notes))
        self.assertTrue(any(note == "codex: pending" for note in notes))
        self.assertFalse(self.login_record("claude").exists())
        self.assertTrue(self.login_record().exists())
        self.assertLessEqual(self.calls("'pane' 'read'"), 8)
        self.assert_no_lifecycle_noise(result)

    def test_exited_logins_without_a_link_require_official_authentication(self):
        for mode, status, code in (("fail-before", "failed", 7), ("zero-without-auth", "failed", 0), ("success-before", "changed", None)):
            with self.subTest(mode=mode):
                write(self.remote / ".codex-fake-mode", mode)
                before = self.calls("'pane' 'read'")
                start = time.monotonic()
                result = self.setup("--json")
                report, steps = self.report(result)
                self.assertLess(time.monotonic() - start, 30)
                self.assertEqual(0 if code is None else 1, result.returncode, result.stdout + result.stderr)
                self.assertEqual(status, steps["logins"])
                if code is not None:
                    self.assertEqual(1, sum(f"login command exited with {code}" in note for note in next(step["notes"] for step in report["steps"] if step["step"] == "logins")))
                self.assertFalse(self.login_record().exists())
                self.assertEqual([], self.remote_workspaces())
                self.assertLessEqual(self.calls("'pane' 'read'") - before, 4)
                self.assert_no_lifecycle_noise(result)

    def test_interactive_login_exit_after_a_link_does_not_wait_for_timeout(self):
        for mode, code in (("fail-after", 9), ("success-after", None)):
            with self.subTest(mode=mode):
                write(self.remote / ".codex-fake-mode", mode)
                before = self.calls("'pane' 'read'")
                start = time.monotonic()
                result = self.interactive_setup()
                self.assertLess(time.monotonic() - start, 30)
                self.assertEqual(0 if code is None else 1, result.returncode, result.stdout + result.stderr)
                self.assertIn("no window here took the notification", result.stdout)
                if code is not None:
                    self.assertEqual(1, result.stdout.count(f"login command exited with {code}"))
                else:
                    self.assertIn("codex: done", result.stdout)
                self.assertFalse(self.login_record().exists())
                self.assertEqual([], self.remote_workspaces())
                self.assertLessEqual(self.calls("'pane' 'read'") - before, 10)
                self.assert_no_lifecycle_noise(result)

    def test_failed_pending_login_is_replaced_on_retry_without_stale_record_noise(self):
        write(self.remote / ".codex-fake-mode", "released")
        self.assertEqual("pending", self.report(self.setup("--json"))[1]["logins"])
        (self.remote / ".codex-release").touch()
        deadline = time.monotonic() + 10
        while self.remote_workspaces() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertEqual([], self.remote_workspaces())
        write(self.remote / ".codex-fake-mode", "fail-before")
        result = self.setup("--json")
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual("failed", self.report(result)[1]["logins"])
        self.assertFalse(self.login_record().exists())
        self.assert_no_lifecycle_noise(result)

    def test_ssh_and_protocol_failures_do_not_become_missing_login_state(self):
        self.assertEqual("pending", self.report(self.setup("--json"))[1]["logins"])
        original = self.login_record().read_text()
        for operation, mode in (("'tab' 'get'", "exit255"), ("'tab' 'get'", "malformed"), ("'tab' 'close'", "exit255")):
            with self.subTest(operation=operation, mode=mode):
                (self.remote / ".codex-fake-auth").touch()
                result = self.setup("--json", fail=operation, mode=mode)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertEqual("failed", self.report(result)[1]["logins"])
                self.assertEqual(original, self.login_record().read_text())
        (self.remote / ".codex-fake-auth").unlink()
        for mode in ("exit255", "malformed"):
            with self.subTest(operation="read", mode=mode):
                result = self.setup("--json", fail="'pane' 'read'", mode=mode)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertEqual("failed", self.report(result)[1]["logins"])

    def test_a_workspace_named_like_a_login_is_never_taken_for_one(self):
        self.assertEqual(0, self.setup("--skip", "login").returncode)
        created = subprocess.run(
            [str(self.remote_telar()), "workspace", "create", "--directory", str(self.remote), "--name", "Log in to Codex", "--json"],
            env=self.remote_environment, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(0, created.returncode, created.stderr)
        persons = (json.loads(created.stdout)["workspace_id"], "Log in to Codex")

        # Setup opens its own login beside the person's workspace...
        report, steps = self.report(self.setup("--json"))
        self.assertEqual("pending", steps["logins"], report)
        self.assertIn(persons, self.remote_workspaces())
        self.assertEqual(2, len(self.remote_workspaces()))

        # ...and closes only its own once the login is done.
        (self.remote / ".codex-fake-auth").touch()
        report, steps = self.report(self.setup("--json"))
        self.assertEqual("ok", steps["logins"], report)
        self.assertEqual([persons], self.remote_workspaces())

    def test_a_failing_ssh_call_fails_its_step_and_the_report_still_comes(self):
        (self.remote / ".codex-fake-auth").touch()
        self.assertEqual(0, self.setup("--json").returncode)

        cases = [
            ("integration install", "exit255", "integrations"),
            ("receive-config", "toolong", "configuration"),
            ("login status", "exit255", "logins"),
        ]
        for text, mode, step in cases:
            with self.subTest(fail=text, mode=mode):
                result = self.setup("--json", fail=text, mode=mode)
                report, steps = self.report(result)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertEqual("failed", steps[step], report)
                # The steps that do not depend on it still ran.
                self.assertEqual("ok", steps["check"], report)
                failed = [name for name, status in steps.items() if status == "failed"]
                self.assertEqual([step], failed, report)

        for mode in ("exit255", "toolong"):
            with self.subTest(fail="probe", mode=mode):
                result = self.setup("--json", fail="uname -s", mode=mode)
                report, steps = self.report(result)
                self.assertEqual(1, result.returncode)
                expected = {"ssh": "failed"} if mode == "exit255" else {"ssh": "ok", "platform": "failed"}
                self.assertEqual(expected, steps, report)
                self.assertFalse(report["ready"])

    def test_a_label_another_machine_has_is_refused_before_anything_is_installed(self):
        added = self.telar("machine", "add", LABEL, "ops@fakebox")
        self.assertEqual(0, added.returncode, added.stderr)

        result = self.setup()
        self.assertEqual(1, result.returncode)
        self.assertIn("--label", result.stderr)
        self.assertFalse((self.remote / ".local/share/telar").exists())

    def test_confirm_without_a_terminal_changes_nothing_and_fails(self):
        for arguments in (("--confirm",), ("--confirm", "--json")):
            with self.subTest(arguments=arguments):
                result = self.setup(*arguments)
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertFalse((self.remote / ".local/share/telar").exists())

        report, steps = self.report(self.setup("--confirm", "--json"))
        self.assertEqual({}, steps)
        self.assertIn("terminal", report["refused"])

    def test_add_with_setup_keeps_disabled_and_prints_one_report(self):
        (self.remote / ".codex-fake-auth").touch()
        result = self.telar(
            "machine", "add", LABEL, DESTINATION, "--disabled", "--check", "--setup", "--binary", str(BINARY), "--json",
        )
        report, steps = self.report(result)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual("changed", steps["profile"])

        listed = json.loads(self.telar("machine", "list", "--json").stdout)
        (profile,) = [machine for machine in listed["machines"] if machine["label"] == LABEL]
        self.assertFalse(profile["enabled"])
        self.assertEqual(str(self.remote_telar()), profile["telar_path"])


if __name__ == "__main__":
    unittest.main()
