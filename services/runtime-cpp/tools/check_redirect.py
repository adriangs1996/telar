#!/usr/bin/env python3
"""Check redirect setup without changes, or use --live for owned loopback PF rules."""

import argparse
import os
import pathlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import json
import selectors


class Origin:
    def __init__(self, address, family=socket.AF_INET):
        self.socket = socket.socket(family, socket.SOCK_STREAM)
        self.socket.bind((address, 0))
        self.socket.listen()
        self.socket.settimeout(0.1)
        self.port = self.socket.getsockname()[1]
        self.stopping = threading.Event()
        self.worker = threading.Thread(target=self.accept, daemon=True)
        self.worker.start()

    def accept(self):
        while not self.stopping.is_set():
            try:
                connection, peer = self.socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self.echo, args=(connection, peer), daemon=True).start()

    @staticmethod
    def echo(connection, peer):
        with connection:
            connection.settimeout(10)
            try:
                connection.sendall(struct.pack("!H", peer[1]))
                while data := connection.recv(65536):
                    connection.sendall(data)
            except OSError:
                pass

    def close(self):
        self.stopping.set()
        self.socket.close()
        self.worker.join(timeout=1)


PROCESS_CLIENT = r'''
import json,sys,types
sys.path.insert(0,sys.argv[1])
from check_redirect import exchange
for line in sys.stdin:
    command=json.loads(line)
    origin=types.SimpleNamespace(socket=types.SimpleNamespace(getsockname=lambda:tuple(command['destination'])),bound_interface=command.get('interface'))
    if command.get('cookie'):
        origin.authenticate=lambda client:client.sendall(bytes.fromhex(command['cookie']))
    exchange(origin,command['redirected'])
    print('verified',flush=True)
'''


class ProcessClient:
    def __init__(self, root):
        self.errors = (root / "process-client.log").open("w")
        self.process = subprocess.Popen([sys.executable, "-u", "-c", PROCESS_CLIENT, str(pathlib.Path(__file__).resolve().parent)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, text=True)

    def exchange(self, origin, redirected):
        command = {"destination": origin.socket.getsockname()[:2], "redirected": redirected, "interface": getattr(origin, "bound_interface", None)}
        if hasattr(origin, "cookie"): command["cookie"] = origin.cookie.hex()
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(15) or self.process.stdout.readline().strip() != "verified":
                raise RuntimeError("Selected process exchange failed; see process-client.log")

    def close(self):
        try: self.process.stdin.close()
        except OSError: pass
        try: self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.errors.close()


def exchange(origin, redirected):
    from network_origin import connect_origin
    with connect_origin(origin.socket.getsockname()[:2], getattr(origin, "bound_interface", None)) as client:
        if hasattr(origin, "authenticate"):
            origin.authenticate(client)
        own_port = client.getsockname()[1]
        peer_port = struct.unpack("!H", client.recv(2, socket.MSG_WAITALL))[0]
        if (own_port != peer_port) != redirected:
            destination = origin.socket.getsockname()[:2]
            raise RuntimeError(f"Unexpected path to {destination}: client port={own_port}, origin saw={peer_port}, expected redirect={redirected}")
        payload = os.urandom(16384)
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        received = bytearray()
        while data := client.recv(65536):
            received.extend(data)
        if received != payload:
            raise RuntimeError("TCP relay changed binary bytes or half-close behavior")


def loopback_status(root, phase):
    arguments = ["sudo", "-n", "/sbin/pfctl", "-v", "-s", "Interfaces", "-i", "lo0"]
    result = subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=5)
    (root / f"loopback-{phase}.log").write_text(result.stdout + result.stderr)
    for line in result.stdout.splitlines():
        if re.fullmatch(r"lo0\s*", line):
            return False
        if re.fullmatch(r"lo0\s+\(skip\)\s*", line):
            return True
    raise RuntimeError("Cannot read PF loopback skip status")


def diagnose(root):
    """Read counters before cleanup removes the rules that explain a failure."""
    commands = [["-si"], ["-vv", "-s", "states"], ["-a", "*", "-vvsr"], ["-a", "*", "-vvsn"], ["-vv", "-s", "Interfaces", "-i", "lo0"]]
    helper_log = root / "helper.log"
    output = helper_log.read_text() if helper_log.exists() else ""
    anchor = re.search(r"anchor (com\.apple/telar-redirect-tlr_[0-9a-f]{16})\b", output)
    if anchor:
        commands.extend([["-a", anchor[1], "-vvsr"], ["-a", anchor[1], "-vvsn"]])
    interface = re.search(r"\bdiscovery (utun[0-9]{1,8})\b", output)
    if interface:
        commands.append(["-vv", "-s", "Interfaces", "-i", interface[1]])
    with (root / "pf-diagnostics.log").open("w") as log:
        for arguments in commands:
            log.write("/sbin/pfctl " + " ".join(arguments) + "\n")
            try:
                result = subprocess.run(["sudo", "-n", "/sbin/pfctl", *arguments], capture_output=True, text=True, timeout=5)
                log.write(result.stdout + result.stderr)
                log.write(f"Exit status: {result.returncode}\n\n")
            except (OSError, subprocess.TimeoutExpired) as error:
                log.write(str(error) + "\n\n")


def shutdown(runtime, helper, binary, endpoint, live):
    errors = []
    if runtime is not None:
        runtime.terminate()
        try:
            runtime.wait(timeout=5)
        except subprocess.TimeoutExpired:
            runtime.kill()
            runtime.wait(timeout=5)
            errors.append("Runtime required SIGKILL during shutdown")
    if helper is not None:
        try:
            status = helper.wait(timeout=20)
            if status != 0:
                errors.append(f"Redirect helper exited with status {status}; see helper.log")
        except subprocess.TimeoutExpired:
            errors.append("Redirect helper did not stop after runtime disconnection")
    if live:
        try:
            result = subprocess.run(["sudo", "-n", str(binary), "traffic", "redirect-cleanup", "--socket", str(endpoint)],
                                    capture_output=True, text=True, timeout=25)
            if result.returncode != 0:
                errors.append("Redirect cleanup failed: " + result.stdout + result.stderr)
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append("Redirect cleanup failed: " + str(error))
    return errors


def check_runtime(binary, live, origins, root, process_selection=False):
    endpoint = root / "runtime.sock"
    config = root / "config.lua"
    config.write_text("return {api_version=2,runtime={proxy={enabled=true,transparent_redirect=true,ca_dir='ca'}}}\n")
    runtime = None
    helper = None
    failed = False
    previous_skip = None
    client = None
    try:
        with (root / "runtime.log").open("w") as log:
            runtime = subprocess.Popen([str(binary), "--socket", str(endpoint), "--config", str(config),
                                        "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        deadline = time.monotonic() + 10
        while not pathlib.Path(str(endpoint) + ".redirect").exists() or not endpoint.exists():
            if runtime.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Runtime did not start: " + (root / "runtime.log").read_text())
            time.sleep(0.01)
        targets = ["--target", f"127.0.0.1:{origins[0].port}", "--target", f"[::1]:{origins[1].port}"]
        for origin in origins[3:]:
            address = origin.socket.getsockname()[0]
            targets.extend(["--target", f"{address}:{origin.port}"])
        command = [str(binary), "traffic", "redirect", "--socket", str(endpoint), *targets]
        if process_selection:
            client = ProcessClient(root)
            command.extend(["--process", str(client.process.pid)])
        plan = subprocess.run([*command, "--dry-run"], check=True, capture_output=True, text=True, timeout=10)
        (root / "dry-run.pf").write_text(plan.stdout)
        if "route-to utun0 inet6" not in plan.stdout or f"user {os.getuid()}" not in plan.stdout or "tagged" in plan.stdout:
            raise RuntimeError("Redirect plan does not preserve its target/user scope")
        exchange(origins[0], False)
        exchange(origins[1], False)
        if live:
            previous_skip = loopback_status(root, "before")
            with (root / "helper.log").open("w") as helper_log:
                helper = subprocess.Popen(["sudo", "-n", *command], stdin=subprocess.DEVNULL, stdout=helper_log, stderr=helper_log)
            deadline = time.monotonic() + 15
            while True:
                output = (root / "helper.log").read_text()
                if "telar redirect: active" in output:
                    break
                if helper.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Redirect activation failed: " + output)
                time.sleep(0.02)
            if loopback_status(root, "active"):
                raise RuntimeError("PF still skips lo0 after redirect activation")
            for family, origin in zip(["IPv4", "IPv6"], origins[:2]):
                try:
                    if client:
                        client.exchange(origin, True)
                        exchange(origin, False)
                    else:
                        exchange(origin, True)
                except Exception as error:
                    raise RuntimeError(f"{family} native redirect failed: {error}") from error
                print(f"{family} native TCP redirect and binary relay verified" + ("; excluded process retains its direct connection" if client else ""), flush=True)
            for origin in origins[3:]:
                if client:
                    client.exchange(origin, True)
                    exchange(origin, False)
                else: exchange(origin, True)
                print(f"Native remote TCP redirect verified: {origin.socket.getsockname()}" + (f"; socket bound to {origin.bound_interface}" if getattr(origin, "bound_interface", None) else ""), flush=True)
            exchange(origins[2], False)
            if client: client.exchange(origins[2], False)
            print("Native IPv4/IPv6 TCP redirect, original destinations, binary data and exclusion verified")
        else:
            print("Actual runtime startup and PF syntax validated; no PF rules or references changed")
    except Exception:
        failed = True
        if live:
            try:
                diagnose(root)
            except Exception as error:
                print(f"Could not collect PF diagnostics: {error}", file=sys.stderr)
        raise
    finally:
        client_errors = []
        if client:
            try:
                client.close()
            except Exception as error:
                client_errors.append(f"Selected process shutdown failed: {error}")
        try:
            errors = shutdown(runtime, helper, binary, endpoint, live)
        except Exception as error:
            errors = [f"Redirect shutdown failed: {error}"]
        errors.extend(client_errors)
        if previous_skip is not None:
            try:
                if loopback_status(root, "after") != previous_skip:
                    errors.append("Redirect cleanup did not restore the original PF loopback skip flag")
            except Exception as error:
                errors.append(f"Could not verify PF loopback restoration: {error}")
        if errors:
            (root / "cleanup-errors.log").write_text("\n".join(errors) + "\n")
            if failed:
                print("\n".join(errors), file=sys.stderr)
            else:
                raise RuntimeError("\n".join(errors))
    if pathlib.Path(str(endpoint) + ".redirect").exists():
        raise RuntimeError("Redirect ingress socket survived runtime shutdown")
    if live:
        exchange(origins[0], False)
        exchange(origins[1], False)
        for origin in origins[3:]:
            exchange(origin, False)
        print("Redirect cleanup, PF loopback restoration and direct connections after shutdown verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--live", action="store_true", help="Ask sudo for the redirect helper only")
    parser.add_argument("--process-selection", action="store_true", help="With --live, redirect a pinned child process and preserve direct connections from the verifier")
    parser.add_argument("--ssh-origin", help="Start a temporary authenticated echo server on a controlled SSH host")
    parser.add_argument("--ssh-address", help="Numeric IPv4 destination for the SSH echo server, including a VPN address")
    parser.add_argument("--bound-interface", help="Explicitly bind remote test sockets to this macOS interface")
    options = parser.parse_args()
    if options.process_selection and not options.live:
        parser.error("--process-selection requires --live")
    if options.ssh_address and not options.ssh_origin:
        parser.error("--ssh-address requires --ssh-origin")
    if options.bound_interface and not options.ssh_origin:
        parser.error("--bound-interface requires --ssh-origin")
    if options.bound_interface:
        socket.if_nametoindex(options.bound_interface)
    if os.geteuid() == 0:
        raise SystemExit("Run as your account; only the redirect helper is elevated.")
    binary = options.runtime.resolve()
    if options.live:
        authorized = subprocess.run(["sudo", "-n", "-v"], capture_output=True).returncode == 0
        if not authorized:
            try:
                with open("/dev/tty"):
                    pass
            except OSError:
                raise SystemExit("Live PF verification needs sudo. Run this command from an interactive terminal.")
            subprocess.run(["sudo", "-v"], check=True)
    root = pathlib.Path(tempfile.mkdtemp(prefix="tlr-redir-", dir="/tmp")).resolve()
    origins = []
    success = False
    try:
        for address, family in [("127.0.0.1", socket.AF_INET), ("::1", socket.AF_INET6), ("127.0.0.1", socket.AF_INET)]:
            origins.append(Origin(address, family))
        if options.ssh_origin:
            from network_origin import RemoteOrigin
            origin = RemoteOrigin(options.ssh_origin, options.ssh_address)
            origins.append(origin)
            if options.bound_interface:
                origin.bound_interface = options.bound_interface
            exchange(origin, False)
            print(f"Direct remote echo verified: {origin.socket.getsockname()}" + (f"; socket bound to {options.bound_interface}" if options.bound_interface else ""), flush=True)
        check_runtime(binary, options.live, origins, root, process_selection=True) if options.process_selection else check_runtime(binary, options.live, origins, root)
        success = True
    except Exception as error:
        (root / "failure.log").write_text(traceback.format_exc())
        print(f"Redirect check failed: {error}\nDiagnostics preserved at {root}", file=sys.stderr)
        return 1
    finally:
        for origin in origins:
            origin.close()
        if success:
            shutil.rmtree(root)


if __name__ == "__main__":
    sys.exit(main())
