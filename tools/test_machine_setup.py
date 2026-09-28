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
`toolong` by printing more than a script may.

Run after `zig build`: python3 tools/test_machine_setup.py
Everything lives in a temporary directory under /tmp and is removed after.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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
command=$*
input=$(mktemp "$FAKE_SSH_ROOT/stdin.XXXXXX")
cat > "$input"
if [ -n "${FAKE_SSH_FAIL:-}" ]; then
    if printf '%s\n' "$command" | grep -qF -- "$FAKE_SSH_FAIL" || grep -qF -- "$FAKE_SSH_FAIL" "$input"; then
        rm -f "$input"
        if [ "${FAKE_SSH_MODE:-exit255}" = toolong ]; then
            head -c 300000 /dev/zero | tr '\0' x
            exit 0
        fi
        echo "ssh: connect to host $destination port 22: Operation timed out" >&2
        exit 255
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
        echo "Welcome to Codex"
        echo "1. Open this link in your browser and sign in to your account"
        echo "   https://auth.openai.com/codex/device"
        echo "2. Enter this one-time code (expires in 15 minutes)"
        echo "   FAKE-1234"
        exec sleep 600 ;;
    *) echo "codex-fake 0.0.0" ;;
esac
"""

FAKE_CLAUDE = r"""#!/bin/sh
case "$1 ${2:-}" in
    "auth status") exit 0 ;;
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

    def remote_workspaces(self):
        listed = subprocess.run(
            [str(self.remote_telar()), "workspace", "list", "--json"],
            env=self.remote_environment, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(0, listed.returncode, listed.stderr)
        return [workspace["name"] for workspace in json.loads(listed.stdout)]

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
        self.assertIn("Log in to Codex", self.remote_workspaces())

        # The person finishes the Codex login in the browser.
        (self.remote / ".codex-fake-auth").touch()
        second = self.setup("--json")
        report, steps = self.report(second)
        self.assertEqual(0, second.returncode, second.stdout + second.stderr)
        self.assertEqual({"ok"}, set(steps.values()), report)
        self.assertTrue(report["ready"])
        self.assertFalse(report["changed"])
        self.assertNotIn("Log in to Codex", self.remote_workspaces())

        third = self.setup()
        self.assertEqual(0, third.returncode, third.stdout + third.stderr)
        self.assertTrue(third.stdout.rstrip().endswith(f"{LABEL} was already set up; nothing changed."), third.stdout)

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
                self.assertEqual({"ssh": "failed"}, steps, report)

    def test_a_label_another_machine_has_is_refused_before_anything_is_installed(self):
        added = self.telar("machine", "add", LABEL, "ops@fakebox")
        self.assertEqual(0, added.returncode, added.stderr)

        result = self.setup()
        self.assertEqual(1, result.returncode)
        self.assertIn("--label", result.stderr)
        self.assertFalse((self.remote / ".local/share/telar").exists())

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
