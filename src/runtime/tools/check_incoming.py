#!/usr/bin/env python3
"""Verify incoming/both redirect scope using a controlled SSH client and local origins."""

import argparse
import contextlib
import json
import os
import pathlib
import shlex
import socket
import subprocess
import sys
import time

from check_redirect import diagnose, exchange, loopback_status, shutdown
from check_traffic import diagnostics_directory
from network_origin import LocalOrigin, RemoteOrigin, controlled_address


CLIENT = r'''
import json,socket,struct,sys
command=json.load(sys.stdin)
def read(connection,size):
    result=bytearray()
    while len(result)<size:
        chunk=connection.recv(size-len(result))
        if not chunk: raise RuntimeError('Incoming echo closed early')
        result.extend(chunk)
    return bytes(result)
with socket.create_connection(tuple(command['destination']),timeout=10) as connection:
    own=connection.getsockname()[:2]
    connection.sendall(bytes.fromhex(command['cookie']))
    address,port=struct.unpack('!4sH',read(connection,6))
    observed=(socket.inet_ntoa(address),port)
    if (observed!=own)!=command['redirected']:
        raise RuntimeError('Unexpected incoming path: client='+repr(own)+', origin='+repr(observed)+', redirected='+str(command['redirected']))
    payload=bytes(range(256))*256+b'incoming\0binary'
    connection.sendall(payload)
    connection.shutdown(socket.SHUT_WR)
    received=bytearray()
    while True:
        chunk=connection.recv(65536)
        if not chunk: break
        received.extend(chunk)
        if len(received)>len(payload): raise RuntimeError('Incoming echo exceeded its message bound')
    if received!=payload: raise RuntimeError('Incoming binary relay or half-close was changed')
print('verified',flush=True)
'''


def client(origin, redirected, host=None):
    command = [sys.executable, "-u", "-c", CLIENT] if host is None else ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5", host, "python3 -u -c " + shlex.quote(CLIENT)]
    request = {"destination": origin.socket.getsockname(), "cookie": origin.cookie.hex(), "redirected": redirected}
    result = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True, timeout=20)
    if result.returncode != 0 or result.stdout.strip() != "verified": raise RuntimeError("Incoming client check failed: " + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--ssh-client", required=True, help="Controlled SSH machine that can connect to this machine")
    parser.add_argument("--ssh-address", help="Numeric IPv4 address of that controlled machine")
    parser.add_argument("--direction", choices=("inbound", "both"), default="both")
    parser.add_argument("--live", action="store_true", help="Elevate the C++ redirect helper; otherwise validate startup, syntax and direct incoming paths only")
    options = parser.parse_args()
    remote_address = controlled_address(options.ssh_client, options.ssh_address)
    if os.geteuid() == 0: parser.error("Run as your account; only the redirect helper is elevated")
    if options.live and subprocess.run(["sudo", "-n", "-v"], capture_output=True).returncode != 0:
        subprocess.run(["sudo", "-v"], check=True)
    binary = options.runtime.resolve()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        route.connect((remote_address, 9))
        address = route.getsockname()[0]
    with diagnostics_directory() as root, contextlib.ExitStack() as resources:
        selected = LocalOrigin(address)
        resources.callback(selected.close)
        excluded = LocalOrigin(address)
        resources.callback(excluded.close)
        outbound = None
        if options.direction == "both":
            outbound = RemoteOrigin(options.ssh_client, remote_address)
            resources.callback(outbound.close)
            exchange(outbound, False)
        client(selected, False, options.ssh_client)
        client(excluded, False, options.ssh_client)
        print("Controlled incoming TCP, authenticated origin and direct binary half-close verified", flush=True)
        endpoint = root / "runtime.sock"
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={enabled=true,transparent_redirect=true,ca_dir='ca'}}}\n")
        runtime = helper = None
        failed = False
        previous_skip = None
        try:
            with (root / "runtime.log").open("w") as log:
                runtime = subprocess.Popen([str(binary), "--socket", str(endpoint), "--config", str(config), "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while not pathlib.Path(str(endpoint) + ".redirect").exists():
                if runtime.poll() is not None or time.monotonic() >= deadline: raise RuntimeError("Incoming runtime did not start: " + (root / "runtime.log").read_text())
                time.sleep(.01)
            command = [str(binary), "traffic", "redirect", "--socket", str(endpoint), "--direction", options.direction, "--target", f"{address}:{selected.port}"]
            if outbound: command.extend(["--target", f"{remote_address}:{outbound.port}"])
            plan = subprocess.run([*command, "--dry-run"], check=True, capture_output=True, text=True, timeout=10)
            (root / "dry-run.pf").write_text(plan.stdout)
            if "pass in log (user, to pflog0) quick on ! lo0" not in plan.stdout: raise RuntimeError("Incoming discovery scope is missing")
            if options.direction == "inbound" and "pass out" in plan.stdout: raise RuntimeError("Incoming-only plan unexpectedly redirects outbound traffic")
            if options.live:
                previous_skip = loopback_status(root, "before")
                with (root / "helper.log").open("w") as log:
                    helper = subprocess.Popen(["sudo", "-n", *command], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                deadline = time.monotonic() + 15
                while "telar redirect: active" not in (root / "helper.log").read_text():
                    if helper.poll() is not None or time.monotonic() >= deadline: raise RuntimeError("Incoming helper did not activate: " + (root / "helper.log").read_text())
                    time.sleep(.02)
                client(selected, True, options.ssh_client)
                client(excluded, False, options.ssh_client)
                client(selected, options.direction == "both")
                if outbound: exchange(outbound, True)
                print("Native incoming TCP redirect, binary relay, half-close, destination exclusion and selected direction verified", flush=True)
            else:
                print("Incoming startup, local scope and actual PF syntax verified; no PF rules or references changed", flush=True)
        except Exception:
            failed = True
            if options.live:
                try:
                    diagnose(root)
                except Exception as error:
                    print(f"Could not collect PF diagnostics: {error}", file=sys.stderr)
            raise
        finally:
            try:
                errors = shutdown(runtime, helper, binary, endpoint, options.live)
            except Exception as error:
                errors = [f"Incoming shutdown failed: {error}"]
            if previous_skip is not None:
                try:
                    if loopback_status(root, "after") != previous_skip: errors.append("Incoming cleanup did not restore PF loopback filtering")
                except Exception as error:
                    errors.append(f"Could not verify PF loopback restoration: {error}")
            if errors:
                (root / "cleanup-errors.log").write_text("\n".join(errors) + "\n")
                if not failed: raise RuntimeError("; ".join(errors))
                print("; ".join(errors), file=sys.stderr)
        client(selected, False, options.ssh_client)
        client(excluded, False, options.ssh_client)
        if outbound: exchange(outbound, False)
        print("Incoming direct connections after shutdown verified" + ("; PF loopback restoration verified" if options.live else ""), flush=True)


if __name__ == "__main__":
    main()
