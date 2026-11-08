#!/usr/bin/env python3
"""Verify native loopback and optional routed-interface capture with a root helper."""

import argparse
import os
import pathlib
import selectors
import select
import shutil
import traceback
import socket
import struct
import subprocess
import tempfile
import time
import contextlib
import json
import re



def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise RuntimeError("Traffic data connection closed")
        result.extend(chunk)
    return result


def event(connection):
    length, _ = struct.unpack("<IQ", read_exact(connection, 12))
    if length > 262144 + 1024:
        raise RuntimeError("Invalid traffic frame length")
    body = read_exact(connection, length)
    header = struct.Struct("<BQQQIIIQQQB")
    kind, _, _, _, _, link_type, _, _, _, _, offline = header.unpack_from(body)
    offset = header.size
    name_length, = struct.unpack_from("<I", body, offset)
    offset += 4
    name = body[offset:offset + name_length].decode()
    offset += name_length
    data_length, = struct.unpack_from("<I", body, offset)
    offset += 4
    if offset + data_length != len(body):
        raise RuntimeError("Invalid traffic event payload")
    return kind, name, link_type, offline, body[offset:]


def routed_capture(options, endpoint, root, helper):
    from network_origin import RemoteOrigin, connect_origin
    origin = RemoteOrigin(options.ssh_origin, options.ssh_address)
    probe = None
    try:
        address, port = origin.socket.getsockname()
        route = subprocess.run(["/sbin/route", "-n", "get", address], check=True, capture_output=True, text=True, timeout=5).stdout
        (root / "capture-route.log").write_text(route)
        found = re.search(r"^\s*interface:\s*(\S+)\s*$", route, re.MULTILINE)
        if not found or found[1] in ("lo", "lo0"):
            raise RuntimeError("Remote capture destination must use a non-loopback interface: " + route)
        interface = options.bound_interface or found[1]
        if options.expected_interface and interface != options.expected_interface:
            raise RuntimeError(f"Remote capture routes through {interface}, expected {options.expected_interface}")
        interface_index = socket.if_nametoindex(interface)
        expressions = [f"tcp and dst host {address} and dst port {port}", f"tcp and src host {address} and src port {port}"]
        token = os.urandom(64)
        with contextlib.ExitStack() as resources:
            channels = [resources.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)) for _ in expressions]
            for channel, expression in zip(channels, expressions):
                channel.connect(str(endpoint) + ".traffic")
                channel.settimeout(2)
                encoded = expression.encode()
                channel.sendall(struct.pack("<IBBI", 0x31525454, 1, 1, len(encoded)) + encoded)
                if event(channel)[0] != 0: raise RuntimeError("Routed capture subscription was not acknowledged")
            if options.lua_probe:
                script = root / "routed-check.lua"
                script.write_text("local expected_interface=" + json.dumps(interface) + "\nlocal expected_index=" + str(interface_index) + "\nlocal token=string.char(" + ",".join(map(str, token)) + ")\nlocal filters={" + ",".join(map(json.dumps, expressions)) + "}\n" + r'''
local traffic=require('telar.traffic')
local stops,seen={},{}
local ready=0
for index,filter in ipairs(filters) do
  stops[index]=traffic.subscribe({events={packet=true},filter=filter},function(err,event)
    assert(not err,err)
    if event.kind=='ready' then
      ready=ready+1
      if ready==2 then test_ready() end
    elseif event.kind=='packet' and event.bytes:find(token,1,true) then
      assert(not event.offline and event.interface==expected_interface and event.interface_index==expected_index)
      assert(not event.truncated and event.subscriber_drops=='0')
      seen[index]=true
      if seen[1] and seen[2] then
        for _,stop in ipairs(stops) do stop() end
        test_done()
      end
    end
  end)
end
''')
                desktop = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode"
                probe = subprocess.Popen([str(options.lua_probe.resolve()), str(endpoint), str(desktop / "ui/api.lua"), str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                with selectors.DefaultSelector() as selector:
                    selector.register(probe.stdout, selectors.EVENT_READ)
                    if not selector.select(10) or probe.stdout.readline().strip() != "ready": raise RuntimeError("Routed Lua subscriptions did not register")
            with connect_origin((address, port), options.bound_interface) as client:
                origin.authenticate(client)
                read_exact(client, 2)
                client.sendall(token)
                if read_exact(client, len(token)) != token: raise RuntimeError("Remote capture echo changed the binary payload")
            pending = set(channels)
            deadline = time.monotonic() + 10
            while pending:
                if helper.poll() is not None or time.monotonic() >= deadline: raise RuntimeError("Routed capture did not observe both directions on " + interface)
                for channel in select.select(list(pending), [], [], .1)[0]:
                    kind, name, link_type, offline, payload = event(channel)
                    if kind == 4 and name == interface: raise RuntimeError("Routed interface capture failed: " + payload.decode(errors="replace"))
                    if kind == 1 and token in payload:
                        if offline or name != interface: raise RuntimeError("Routed capture provenance does not match the selected interface")
                        pending.remove(channel)
            if probe:
                output, errors = probe.communicate(timeout=10)
                (root / "routed-probe.stdout").write_text(output)
                (root / "routed-probe.stderr").write_text(errors)
                if probe.returncode != 0 or "packet verified" not in output: raise RuntimeError(f"Routed Desktop Lua capture failed: {output} {errors}")
            print(f"Native routed-interface capture verified: interface={interface}, destination={address}:{port}, outbound/inbound binary payload" + (", Desktop Lua and cancellation" if probe else "") + (", interface-bound socket" if options.bound_interface else ""), flush=True)
    finally:
        try:
            if probe is not None:
                if probe.poll() is None: probe.terminate()
                output, errors = probe.communicate(timeout=5)
                if output: (root / "routed-probe.stdout").write_text(output)
                if errors: (root / "routed-probe.stderr").write_text(errors)
        finally:
            origin.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, help="Also verify native packets through the real Desktop Lua API")
    parser.add_argument("--ssh-origin", help="Controlled SSH host for an authenticated capture echo origin")
    parser.add_argument("--ssh-address", help="Numeric IPv4 destination of the controlled echo origin")
    parser.add_argument("--expected-interface", help="Require the routed destination to use this capture interface")
    parser.add_argument("--bound-interface", help="Explicitly bind remote test sockets to this macOS interface")
    parser.add_argument("--interface-probe", type=pathlib.Path, help="C++ traffic-interface-probe executable for owned virtual-interface creation/removal checks")
    options = parser.parse_args()
    if (options.ssh_address or options.expected_interface or options.bound_interface) and not options.ssh_origin:
        parser.error("--ssh-address, --expected-interface and --bound-interface require --ssh-origin")
    if options.bound_interface:
        socket.if_nametoindex(options.bound_interface)
    if os.geteuid() == 0:
        raise SystemExit("Run this check as your account. It elevates only the capture helper.")
    binary = options.runtime.resolve()
    subprocess.run(["sudo", "-v"], check=True)

    root = pathlib.Path(tempfile.mkdtemp(prefix="telar-traffic-live-", dir="/tmp")).resolve()
    endpoint = root / "runtime.sock"
    config = root / "config.lua"
    config.write_text("return {api_version=2,runtime={proxy={network_capture=true}}}\n")
    runtime = helper = probe = None
    failed = False
    cleanup_errors = []
    try:
        with (root / "runtime.log").open("w+") as log, (root / "helper.log").open("w") as helper_log:
            runtime = subprocess.Popen([str(binary), "--socket", str(endpoint), "--config", str(config),
                                        "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while not endpoint.exists():
                if runtime.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise RuntimeError("Runtime did not start: " + log.read())
                time.sleep(0.01)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver, \
                    socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender, \
                    socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as data:
                receiver.bind(("127.0.0.1", 0))
                receiver.settimeout(2)
                port = receiver.getsockname()[1]
                expression = f"udp port {port}".encode()
                data.connect(str(endpoint) + ".traffic")
                data.settimeout(2)
                data.sendall(struct.pack("<IBBI", 0x31525454, 1, 1, len(expression)) + expression)
                if event(data)[0] != 0:
                    raise RuntimeError("Traffic subscription was not acknowledged")
                token = os.urandom(32)
                if options.lua_probe:
                    desktop = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode"
                    check = root / "native-check.lua"
                    check.write_text("local t=require('telar.traffic'); local stop; stop=t.subscribe({events={packet=true},filter='udp port " + str(port) + "'},function(err,e) assert(not err,err); if e.kind=='ready' then test_ready() end; if e.kind=='packet' and e.bytes:sub(-32)==string.char(" + ",".join(map(str,token)) + ") then assert(not e.offline); stop(); test_done() end end)\n")
                    probe = subprocess.Popen([str(options.lua_probe.resolve()), str(endpoint), str(desktop / "ui/api.lua"), str(check)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    with selectors.DefaultSelector() as selector:
                        selector.register(probe.stdout, selectors.EVENT_READ)
                        if not selector.select(10) or probe.stdout.readline().strip() != "ready":
                            raise RuntimeError("Native Lua subscriber did not register")
                helper = subprocess.Popen(["sudo", "-n", str(binary), "traffic", "capture", "--socket", str(endpoint)], stdin=subprocess.DEVNULL, stdout=helper_log, stderr=helper_log)
                deadline = time.monotonic() + 15
                verified = False
                while not verified or (probe is not None and probe.poll() is None):
                    if time.monotonic() > deadline or helper.poll() is not None:
                        raise RuntimeError("Native loopback packet did not arrive; see helper.log")
                    if probe is not None and probe.poll() not in (None, 0):
                        raise RuntimeError("Native Lua subscriber exited before capture completed")
                    sender.sendto(token, receiver.getsockname())
                    if receiver.recv(128) != token:
                        raise RuntimeError("Loopback datagram changed")
                    if not select.select([data], [], [], 0.1)[0]:
                        continue
                    kind, name, link_type, offline, payload = event(data)
                    if kind == 4 and name in ("lo", "lo0"):
                        raise RuntimeError("Loopback capture failed: " + payload.decode(errors="replace"))
                    if kind == 1 and payload.endswith(token):
                        if offline or name not in ("lo", "lo0"):
                            raise RuntimeError("Native packet provenance is incorrect")
                        if not verified:
                            print(f"Native loopback capture verified: interface={name} link_type={link_type}", flush=True)
                        verified = True
                if probe is not None:
                    output, error = probe.communicate(timeout=5)
                    (root / "probe.stdout").write_text(output)
                    (root / "probe.stderr").write_text(error)
                    if probe.returncode != 0 or "packet verified" not in output:
                        raise RuntimeError(f"Native Desktop Lua capture failed: {output} {error}")
                    print("Native capture -> Desktop Lua, binary payload and cancellation verified", flush=True)
            if options.ssh_origin:
                routed_capture(options, endpoint, root, helper)
            if options.interface_probe:
                from check_interface_changes import interface_changes
                interface_changes(options, endpoint, root, helper)
    except Exception:
        failed = True
        (root / "failure.log").write_text(traceback.format_exc())
        raise
    finally:
        for name, process in (("probe", probe), ("runtime", runtime), ("helper", helper)):
            if process is None:
                continue
            try:
                if name != "helper" and process.poll() is None:
                    process.terminate()
                status = process.wait(timeout=10)
                if name == "helper" and status != 0:
                    cleanup_errors.append(f"Capture helper exited with status {status}")
            except (OSError, subprocess.TimeoutExpired) as error:
                cleanup_errors.append(f"{name}: {error}")
        if pathlib.Path(str(endpoint) + ".traffic").exists():
            cleanup_errors.append("Traffic socket was not cleaned up")
        if cleanup_errors:
            (root / "cleanup-errors.log").write_text("\n".join(cleanup_errors))
        if failed or cleanup_errors:
            print(f"Native capture diagnostics preserved at {root}", flush=True)
        else:
            shutil.rmtree(root)
        if cleanup_errors and not failed:
            raise RuntimeError("; ".join(cleanup_errors))


if __name__ == "__main__":
    main()
