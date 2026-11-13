import contextlib
import io
import os
import socket
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_redirect as check
import check_incoming as incoming
from network_origin import connect_origin


class RedirectCheckTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "macOS interface binding fixture")
    def test_interface_bound_ipv4_ipv6_binary_echo(self):
        for address, family in [("127.0.0.1", socket.AF_INET), ("::1", socket.AF_INET6)]:
            with self.subTest(address=address), contextlib.closing(check.Origin(address, family)) as origin:
                origin.bound_interface = "lo0"
                check.exchange(origin, False)

    @unittest.skipUnless(sys.platform == "darwin", "macOS interface binding fixture")
    def test_bound_selected_process_uses_the_same_socket_binding(self):
        with tempfile.TemporaryDirectory() as temporary, \
             contextlib.closing(check.Origin("127.0.0.1")) as origin, \
             contextlib.closing(check.ProcessClient(Path(temporary))) as selected:
            origin.bound_interface = "lo0"
            selected.exchange(origin, False)

    @unittest.skipUnless(sys.platform == "darwin", "macOS interface binding fixture")
    def test_missing_bound_interface_fails_before_connecting(self):
        with self.assertRaises(OSError):
            connect_origin(("127.0.0.1", 9), "tlr-no-such-if")

    def test_incoming_failure_survives_diagnostics_and_cleanup_errors(self):
        for failed in [True, False]:
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                endpoint = root / "runtime.sock"
                output = io.StringIO()

                def launch(arguments, **options):
                    if arguments[0] == "sudo":
                        options["stderr"].write("telar redirect: active\n")
                        options["stderr"].flush()
                    else:
                        Path(str(endpoint) + ".redirect").touch()
                    return Mock()

                def run(arguments, **options):
                    plan = "pass in log (user, to pflog0) quick on ! lo0\n" if arguments[-1] == "--dry-run" else ""
                    return subprocess.CompletedProcess(arguments, 0, plan, "")

                with patch.object(sys, "argv", ["check_incoming.py", "--runtime", "/runtime", "--ssh-client", "controlled", "--direction", "inbound", "--live"]), \
                     patch.object(incoming.os, "geteuid", return_value=501), \
                     patch.object(incoming, "controlled_address", return_value="192.0.2.1"), \
                     patch.object(incoming, "diagnostics_directory", return_value=contextlib.nullcontext(root)), \
                     patch.object(incoming, "LocalOrigin"), \
                     patch.object(incoming.socket, "socket") as route, \
                     patch.object(incoming.subprocess, "run", side_effect=run), \
                     patch.object(incoming.subprocess, "Popen", side_effect=launch), \
                     patch.object(incoming, "client", side_effect=[None, None, RuntimeError("original incoming path failure")] if failed else None), \
                     patch.object(incoming, "diagnose", side_effect=OSError("diagnostics unavailable")) as diagnostics, \
                     patch.object(incoming, "shutdown", side_effect=OSError("shutdown unavailable")), \
                     patch.object(incoming, "loopback_status", side_effect=[True, OSError("loopback unavailable")]), \
                     contextlib.redirect_stderr(output), contextlib.redirect_stdout(io.StringIO()):
                    route.return_value.__enter__.return_value.getsockname.return_value = ("192.0.2.2", 1234)
                    expected = "^original incoming path failure$" if failed else "Incoming shutdown failed"
                    with self.assertRaisesRegex(RuntimeError, expected):
                        incoming.main()
                self.assertEqual(diagnostics.call_count, int(failed))
                if failed:
                    self.assertIn("diagnostics unavailable", output.getvalue())
                cleanup = (root / "cleanup-errors.log").read_text()
                self.assertIn("shutdown unavailable", cleanup)
                self.assertIn("loopback unavailable", cleanup)

    def test_original_failure_survives_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            endpoint = root / "runtime.sock"
            anchor = "com.apple/telar-redirect-tlr_0123456789abcdef"
            native_commands = []

            def launch(arguments, **options):
                if arguments[0] == "sudo":
                    options["stderr"].write(f"telar redirect: active for uid {os.getuid()}, 2 TCP destinations, anchor {anchor}\n")
                    options["stderr"].flush()
                else:
                    endpoint.touch()
                    Path(str(endpoint) + ".redirect").touch()
                return Mock()

            def run(arguments, **options):
                if arguments[-1] == "--dry-run":
                    return subprocess.CompletedProcess(arguments, 0, f"route-to utun0 inet6 user {os.getuid()}\n", "")
                native_commands.append(arguments)
                return subprocess.CompletedProcess(arguments, 0, "PF counters\n", "ALTQ notice\n")

            def shutdown(*arguments):
                self.assertTrue((root / "pf-diagnostics.log").exists(), "Capture counters before removing rules")
                return ["injected cleanup failure"]

            origins = [Mock(port=1234), Mock(port=1235), Mock(port=1236)]
            with patch.object(check.subprocess, "Popen", side_effect=launch), \
                 patch.object(check.subprocess, "run", side_effect=run), \
                 patch.object(check, "loopback_status", side_effect=[True, False, True]), \
                 patch.object(check, "exchange", side_effect=[None, None, RuntimeError("original path failure")]), \
                 patch.object(check, "shutdown", side_effect=shutdown), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "^IPv4 native redirect failed: original path failure$") as failure:
                    check.check_runtime(Path("/runtime"), True, origins, root)
                self.assertEqual(str(failure.exception.__cause__), "original path failure")
            self.assertIn(["sudo", "-n", "/sbin/pfctl", "-vv", "-s", "states"], native_commands)
            self.assertIn(["sudo", "-n", "/sbin/pfctl", "-a", anchor, "-vvsr"], native_commands)
            self.assertIn(["sudo", "-n", "/sbin/pfctl", "-a", anchor, "-vvsn"], native_commands)
            self.assertIn("PF counters", (root / "pf-diagnostics.log").read_text())
            self.assertIn("injected cleanup failure", (root / "cleanup-errors.log").read_text())

    def test_main_preserves_failed_artifacts_and_removes_successful_ones(self):
        for failure in [True, False]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "artifacts"
                root.mkdir(mode=0o700)
                output = io.StringIO()
                with patch.object(sys, "argv", ["check_redirect.py", "--runtime", "/runtime"]), \
                     patch.object(check.os, "geteuid", return_value=501), \
                     patch.object(check.tempfile, "mkdtemp", return_value=str(root)), \
                     patch.object(check, "Origin"), \
                     patch.object(check, "check_runtime", side_effect=RuntimeError("original failure") if failure else None), \
                     contextlib.redirect_stderr(output):
                    status = check.main()
                if failure:
                    self.assertEqual(status, 1)
                    self.assertIn("original failure", (root / "failure.log").read_text())
                    self.assertIn(str(root), output.getvalue())
                else:
                    self.assertFalse(root.exists())


if __name__ == "__main__":
    unittest.main()
