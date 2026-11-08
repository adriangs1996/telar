import argparse
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import selectors
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("check_traffic_live", Path(__file__).resolve().parents[1] / "tools/check_traffic_live.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_traffic as control_check


class HelperBoundaryReached(Exception):
    pass


class NetworkCheckTest(unittest.TestCase):
    def test_binary_relay_cleanup_without_flow_notifications(self):
        if self.lua_probe is None:
            self.skipTest("Supply --lua-probe to exercise actual Desktop Lua coordination")

        with control_check.diagnostics_directory() as root, socket.socket() as origin:
            endpoint = root / "runtime.sock"
            config = root / "config.lua"
            config.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,network_control=true,anonymous_tunnels=true,transparent_redirect=true,intercept_hosts={},capture={enabled=false},ca_dir='ca'}}}\n")
            origin.bind(("127.0.0.1", 0))
            origin.listen()
            origin.settimeout(10)
            received, failures = [], []
            worker = threading.Thread(target=control_check.echo_origin, args=(origin, received, failures), daemon=True)
            worker.start()
            script = root / "continuation.lua"
            script.write_text("""
local traffic=require('telar.traffic')
local ready=false
local stop
stop=traffic.subscribe({events={packet=true}},function(err,event)
  assert(not err,err)
  assert(not event.kind:match('^flow%.'), 'No flow notifications may drive completion')
  if event.kind=='ready' then ready=true; test_ready() end
end)
function test_exchange_complete()
  assert(ready)
  stop()
  traffic.redirect.stop(function(err,reply)
    assert(not err,err)
    assert(reply.result=='ok' and reply.redirect.state=='idle',reply.message)
    test_done()
  end)
end
""")
            api = Path(__file__).resolve().parents[2] / "desktop-mode/ui/api.lua"
            with (root / "runtime.log").open("w") as log:
                runtime = subprocess.Popen([str(self.runtime), "--socket", str(endpoint), "--config", str(config), "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                probe = None
                try:
                    deadline = time.monotonic() + 10
                    while not Path(str(endpoint) + ".network").exists():
                        self.assertIsNone(runtime.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.01)
                    probe = subprocess.Popen([str(self.lua_probe), str(endpoint), str(api), str(script)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                        env={**os.environ, "TELAR_TRAFFIC_PROBE_INPUT": "1"})
                    with selectors.DefaultSelector() as selector:
                        selector.register(probe.stdout, selectors.EVENT_READ)
                        self.assertTrue(selector.select(5))
                        self.assertEqual(probe.stdout.readline().strip(), "ready")
                    proxy_port = int(next((root / "ca").glob("proxy-port-*")).read_text().splitlines()[0])
                    payload = bytes(range(256)) * 256 + b"native\0control"
                    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as tunnel:
                        target = f"127.0.0.1:{origin.getsockname()[1]}"
                        tunnel.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                        head = bytearray()
                        while not head.endswith(b"\r\n\r\n"):
                            part = tunnel.recv(1)
                            self.assertTrue(part)
                            head.extend(part)
                            self.assertLessEqual(len(head), 4096)
                        self.assertTrue(head.startswith(b"HTTP/1.1 200 "), head)
                        tunnel.sendall(payload)
                        tunnel.shutdown(socket.SHUT_WR)
                        response = bytearray()
                        while part := tunnel.recv(65536): response.extend(part)
                        self.assertEqual(response, payload)
                    output, errors = probe.communicate(input="c", timeout=5)
                    (root / "probe.stdout").write_text(output)
                    (root / "probe.stderr").write_text(errors)
                    self.assertEqual(probe.returncode, 0, errors)
                    self.assertIn("packet verified", output)
                    direct = b"direct\0after-control"
                    own_port = control_check.echo_exchange(origin.getsockname(), direct)
                    worker.join(timeout=2)
                    self.assertFalse(worker.is_alive())
                    self.assertEqual(failures, [])
                    self.assertEqual(len(received), 2)
                    self.assertEqual(received[0][1], payload)
                    self.assertEqual(received[1], (own_port, direct))
                finally:
                    if probe is not None:
                        if probe.poll() is None: probe.terminate()
                        probe.communicate(timeout=5)
                    runtime.terminate()
                    runtime.wait(timeout=10)

    @unittest.skipIf(os.geteuid() == 0, "The native checker requires an ordinary account")
    def test_live_capture_starts_with_long_tmpdir(self):
        processes = []
        directories = []
        real_popen = subprocess.Popen

        def launch(arguments, **options):
            if arguments[0] == "sudo":
                endpoint = Path(arguments[arguments.index("--socket") + 1])
                self.assertTrue(stat.S_ISSOCK(endpoint.stat().st_mode))
                self.assertTrue(stat.S_ISSOCK(Path(str(endpoint) + ".traffic").stat().st_mode))
                # Exercise startup and the real subscription handshake, stopping before elevation.
                raise HelperBoundaryReached()
            endpoint = Path(arguments[arguments.index("--socket") + 1])
            directories.append(endpoint.parent)
            process = real_popen(arguments, **options)
            processes.append(process)
            return process

        def authorize(arguments, **options):
            self.assertEqual(arguments, ["sudo", "-v"])
            return subprocess.CompletedProcess(arguments, 0)

        try:
            with tempfile.TemporaryDirectory(prefix="tlr-path-test-", dir="/tmp") as temporary:
                parent = Path(temporary).resolve()
                ambient = parent / ("t" * (55 - len(os.fsencode(parent)) - 1))
                ambient.mkdir(mode=0o700)
                with patch.dict(os.environ, {"TMPDIR": str(ambient)}), \
                     patch.object(tempfile, "tempdir", None), \
                     patch.object(sys, "argv", ["check_traffic_live.py", "--runtime", str(self.runtime)]), \
                     patch.object(check.subprocess, "run", side_effect=authorize), \
                     patch.object(check.subprocess, "Popen", side_effect=launch), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(Path(tempfile.gettempdir()), ambient)
                    with self.assertRaises(HelperBoundaryReached):
                        check.main()
            self.assertEqual(len(processes), 1)
            self.assertEqual(processes[0].returncode, 0)
            self.assertFalse((directories[0] / "runtime.sock").exists())
            self.assertFalse((directories[0] / "runtime.sock.traffic").exists())
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            for directory in directories:
                shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--lua-probe", type=Path)
    options, remaining = parser.parse_known_args()
    NetworkCheckTest.runtime = options.runtime.resolve()
    NetworkCheckTest.lua_probe = options.lua_probe.resolve() if options.lua_probe else None
    unittest.main(argv=[sys.argv[0], *remaining])
