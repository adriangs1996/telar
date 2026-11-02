#!/usr/bin/env python3
"""Verify digest-authorized runtime Lua apps and real proxy rewrites without sudo."""

import argparse
import contextlib
import gzip
import json
import os
import pathlib
import selectors
import socket
import subprocess
import threading
import time
import signal

from check_traffic import diagnostics_directory, fixture
from check_traffic_hooks import read_http_message
from check_plugin_startup import package


FIRST = r'''
local traffic = require('telar.traffic')
local original
local stop
stop = traffic.intercept({stage='http',host='127.0.0.1',failure='allow',timeout_ms=2500},function(err,event)
  assert(not err,err)
  if event.kind ~= 'http.intercept.request' then return end
  local message = event.message
  assert(event.app.id == 'rewriter-first')
  if not message.response and message.target == '/cancel' then
    original = event
    stop()
    traffic.intercept({stage='http',host='127.0.0.1',direction='outbound',failure='allow'},function(err,current)
      assert(not err,err)
      if current.kind ~= 'http.intercept.request' then return end
      assert(not original.respond({action='reject'}))
      return {action='replace',target=current.message.target..'/c',body=current.message.body..'\0c'}
    end)
    return
  end
  if message.response then
    return {action='replace',status=201,body=message.body..'\0a'}
  end
  return {action='replace',target=message.target..'/a',body=message.body..'\0a'}
end)
return {}
'''

SECOND = r'''
local traffic = require('telar.traffic')
local failed = {}
local guard = false
local guard_ready = false
traffic.intercept({stage='http',host='127.0.0.1',failure='allow',timeout_ms=2500},function(err,event)
  assert(not err,err)
  if event.kind ~= 'http.intercept.request' then return end
  assert(event.app.id == 'rewriter-second')
  local message = event.message
  if not message.response and message.target == '/arm-guard/a' and not guard then
    guard = true
    traffic.intercept({stage='http',host='127.0.0.1',direction='outbound',failure='reject'},function(err,current)
      assert(not err,err)
      if current.kind == 'ready' then guard_ready = true end
      if current.kind == 'http.intercept.request' then return {action='allow'} end
    end)
  end
  if not message.response and message.target == '/guard-ready/a' and guard_ready then
    return {action='replace',target=message.target..'/armed',body=message.body..'\0b'}
  end
  if not message.response and message.target == '/fail/a' then
    failed[event.flow_id] = true
    error('intentional app failure')
  end
  if failed[event.flow_id] then return {action='allow'} end
  if message.response then
    return {action='replace',status=202,body=message.body..'\0b'}
  end
  return {action='replace',target=message.target..'/b',body=message.body..'\0b'}
end)
return {}
'''

OBSERVER = r'''
local traffic = require('telar.traffic')
local allowed, message = pcall(function() traffic.intercept({host='*'},function() end) end)
assert(not allowed and message:find('capability denied'))
traffic.subscribe({events={flow=true}},function(err,event) assert(not err,err) end)
return {}
'''

PACKET = r'''
local traffic = require('telar.traffic')
local ready = false
local seen = false
traffic.subscribe({events={packet=true},filter='udp dst port 53535'},function(err,event)
  assert(not err,err)
  if event.kind == 'ready' then ready = true end
  if event.kind == 'packet' then
    assert(event.interface == 'offline' and event.offline)
    assert(event.link_type == 1 and event.captured_bytes == #event.bytes and not event.truncated)
    assert(event.bytes:sub(-3) == 'a\0b' and event.app.id == 'packet-bridge')
    seen = true
  end
end)
traffic.intercept({stage='http',host='127.0.0.1',direction='outbound',failure='allow'},function(err,event)
  assert(not err,err)
  if event.kind ~= 'http.intercept.request' then return end
  local message = event.message
  if ready and message.target:find('^/ready') then return {action='replace',target=message.target..'/p'} end
  if seen and message.target:find('^/packet%-check') then return {action='replace',target=message.target..'/packet',body=message.body..'\0packet'} end
  if message.target:find('^/digest%-check') then return {action='replace',body=message.body..':digest='..event.app.digest} end
  return {action='allow'}
end)
return {}
'''


def receive_head(connection):
    head = bytearray()
    while not head.endswith(b"\r\n\r\n"):
        data = connection.recv(1)
        if not data or len(head) >= 4096:
            raise RuntimeError("Invalid CONNECT acknowledgement")
        head.extend(data)
    return bytes(head)


def worker_process(runtime, index):
    processes = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, check=True).stdout.splitlines()
    candidates = []
    suffix = f"/package-{index}/main.lua"
    for line in processes:
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and int(fields[1]) == runtime.pid and "tap-worker" in fields[2]:
            entry = next((part for part in fields[2].split() if part.endswith(suffix)), None)
            if entry: candidates.append((int(fields[0]), pathlib.Path(entry)))
    if len(candidates) != 1: raise RuntimeError(f"Cannot identify the runtime-owned Lua worker {index}: {candidates}")
    return candidates[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    options = parser.parse_args()
    binary = options.runtime.resolve()
    probe = options.lua_probe.resolve()
    desktop = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode"
    with diagnostics_directory() as root, contextlib.ExitStack() as resources:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update(XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"), XDG_RUNTIME_DIR=str(root / "run"), SHELL="/bin/sh")
        (root / "run").mkdir(mode=0o700)
        configured = []
        packages, digests = {}, {}
        for name, source, capabilities in (("rewriter-first", FIRST, ["traffic.intercept"]), ("rewriter-second", SECOND, ["traffic.intercept"]), ("packet-bridge", PACKET, ["traffic.observe", "traffic.intercept"]), ("observer", OBSERVER, ["traffic.observe"])):
            directory = package(root, name, capabilities=capabilities)
            packages[name] = directory
            (directory / "main.lua").write_text(source)
            if name == "observer":
                denied = subprocess.run([str(binary), "plugin", "trust", str(directory), "--capability", "traffic.intercept"], env=environment, capture_output=True, text=True, timeout=5)
                if denied.returncode == 0:
                    raise RuntimeError("CLI granted an undeclared interception capability")
            subprocess.run([str(binary), "plugin", "trust", str(directory)], env=environment, capture_output=True, check=True, timeout=5)
            inspection = subprocess.run([str(binary), "plugin", "inspect", str(directory)], env=environment, capture_output=True, check=True, text=True, timeout=5)
            digests[name] = next(line.removeprefix("digest: ") for line in inspection.stdout.splitlines() if line.startswith("digest: "))
            configured.append("{path=" + json.dumps(str(directory)) + "}")
        configuration = root / "config.lua"
        configuration.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,stream_interception=true,anonymous_tunnels=true,intercept_hosts={},capture={enabled=false},ca_dir='ca'}},plugins={" + ",".join(configured) + "}}")
        endpoint = root / "runtime.sock"
        listener = resources.enter_context(socket.socket())
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(.1)
        received, failures = [], []
        done = threading.Event()
        response_body = b"origin\0response" + bytes(range(256)) * 1024

        def origin():
            while not done.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                try:
                    with connection:
                        connection.settimeout(5)
                        if not connection.recv(1, socket.MSG_PEEK): continue
                        line, headers, body, _ = read_http_message(connection)
                        received.append((line.split()[1], gzip.decompress(body)))
                        encoded = gzip.compress(response_body)
                        connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
                except Exception as error:
                    failures.append(error)
                    return

        worker = threading.Thread(target=origin, daemon=True)
        worker.start()
        observer = None
        with (root / "runtime.log").open("w+") as log:
            runtime = subprocess.Popen([str(binary), "--socket", str(endpoint), "--config", str(configuration), "--history", ":memory:", "--no-session"], env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic() >= deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: " + log.read())
                    time.sleep(.01)
                port = int(next((root / "ca").glob("proxy-port-*")).read_text().splitlines()[0])

                def exchange(target, body):
                    before = len(received)
                    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
                        destination = f"127.0.0.1:{listener.getsockname()[1]}"
                        connection.sendall(f"CONNECT {destination} HTTP/1.1\r\nHost: {destination}\r\n\r\n".encode())
                        if not receive_head(connection).startswith(b"HTTP/1.1 200 "):
                            raise RuntimeError("CONNECT was rejected")
                        encoded = gzip.compress(body)
                        connection.sendall(b"POST " + target + b" HTTP/1.1\r\nHost: fixture.test\r\nContent-Encoding: gzip\r\nContent-Length: " + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
                        line, _, response, _ = read_http_message(connection)
                    if failures or len(received) != before + 1:
                        raise RuntimeError(f"Unexpected origin deliveries: {received}, {failures}")
                    return received[-1], int(line.split()[1]), gzip.decompress(response)

                deadline = time.monotonic() + 10
                while True:
                    request, status, response = exchange(b"/ready", b"warmup\0")
                    if request == (b"/ready/a/b/p", b"warmup\0\0a\0b") and status == 202 and response == response_body + b"\0a\0b": break
                    if time.monotonic() >= deadline:
                        raise RuntimeError(f"Workers did not register in configuration order: {request}, status={status}, errors={failures}")
                    time.sleep(.02)

                script = root / "desktop.lua"
                script.write_text("local stop; stop=require('telar.traffic').subscribe({events={flow=true}},function(err,event) assert(not err,err); if event.kind=='ready' then test_ready() end; if event.kind=='flow.error' and event.reason=='app_callback_error:rewriter-second' then stop();test_done() end end)")
                observer = subprocess.Popen([str(probe), str(endpoint), str(desktop / "ui/api.lua"), str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                with selectors.DefaultSelector() as selector:
                    selector.register(observer.stdout, selectors.EVENT_READ)
                    if not selector.select(5) or observer.stdout.readline().strip() != "ready": raise RuntimeError("Desktop observer did not register")
                body = bytes(range(256)) * 2048 + b"client\0body"
                capture = root / "fixture.pcap"
                fixture(capture, 53536)
                subprocess.run([str(binary), "traffic", "import", "--socket", str(endpoint), "--file", str(capture)], env=environment, check=True, timeout=5)
                request, _, _ = exchange(b"/packet-check", body)
                if request != (b"/packet-check/a/b", body + b"\0a\0b"):
                    raise RuntimeError("A packet outside the worker BPF filter reached Lua")
                fixture(capture)
                subprocess.run([str(binary), "traffic", "import", "--socket", str(endpoint), "--file", str(capture)], env=environment, check=True, timeout=5)
                deadline = time.monotonic() + 5
                while True:
                    request, _, _ = exchange(b"/packet-check", body)
                    if request == (b"/packet-check/a/b/packet", body + b"\0a\0b\0packet"): break
                    if time.monotonic() >= deadline: raise RuntimeError("A captured packet did not reach the same persistent Lua app as its HTTP hook")
                request, _, _ = exchange(b"/digest-check", body)
                if request != (b"/digest-check/a/b", body + b"\0a\0b:digest=" + digests["packet-bridge"].encode()):
                    raise RuntimeError("The traffic callback did not receive its authorized package digest")
                request, status, response = exchange(b"/fail", body)
                if request != (b"/fail/a", body + b"\0a") or response != response_body + b"\0a":
                    raise RuntimeError("Worker failure lost an earlier app's replacement")
                output, errors = observer.communicate(timeout=5)
                if observer.returncode or "packet verified" not in output: raise RuntimeError(f"App failure was not observable: {output} {errors}")
                request, status, response = exchange(b"/after-desktop", body)
                if request != (b"/after-desktop/a/b", body + b"\0a\0b") or status != 202 or response != response_body + b"\0a\0b":
                    raise RuntimeError("Runtime hooks failed after Desktop disconnected")
                request, _, response = exchange(b"/cancel", body)
                if request != (b"/cancel/b", body + b"\0b") or response != response_body + b"\0b":
                    raise RuntimeError("New registration joined an already pending message or cancellation discarded another app's edit")
                request, _, response = exchange(b"/new-registration", body)
                if request != (b"/new-registration/c/b", body + b"\0c\0b") or response != response_body + b"\0b":
                    raise RuntimeError("Dynamic registration order or stale responder cancellation failed")
                (packages["rewriter-first"] / "main.lua").write_text("error('untrusted source edit must never be loaded')")
                child, _ = worker_process(runtime, 0)
                os.kill(child, signal.SIGKILL)
                deadline = time.monotonic() + 5
                while True:
                    request, _, _ = exchange(b"/restarted", body)
                    if request == (b"/restarted/a/b", body + b"\0a\0b"): break
                    if time.monotonic() >= deadline: raise RuntimeError("The crashed worker did not recover from its verified snapshot")
                request, _, _ = exchange(b"/packet-check", body)
                if request != (b"/packet-check/a/b/packet", body + b"\0a\0b\0packet"):
                    raise RuntimeError("Restarting one app reset another app's packet state")
                exchange(b"/arm-guard", b"arm")
                deadline = time.monotonic() + 5
                while True:
                    request, _, _ = exchange(b"/guard-ready", b"ready")
                    if request[0] == b"/guard-ready/a/armed": break
                    if time.monotonic() >= deadline: raise RuntimeError("Fail-closed guard did not register")
                child, snapshot = worker_process(runtime, 1)
                snapshot.rename(snapshot.with_name("unavailable.lua"))
                os.kill(child, signal.SIGKILL)
                delivered = len(received)
                for _ in range(4):
                    with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
                        destination = f"127.0.0.1:{listener.getsockname()[1]}"
                        connection.sendall(f"CONNECT {destination} HTTP/1.1\r\nHost: {destination}\r\n\r\n".encode())
                        if not receive_head(connection).startswith(b"HTTP/1.1 200 "): raise RuntimeError("Guard CONNECT was rejected before its HTTP policy")
                        encoded = gzip.compress(b"must not reach origin")
                        connection.sendall(b"POST /guarded HTTP/1.1\r\nHost: fixture.test\r\nContent-Encoding: gzip\r\nContent-Length: " + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
                        try:
                            leaked = connection.recv(1)
                        except ConnectionResetError:
                            leaked = b""
                        if leaked: raise RuntimeError("A failed Lua worker bypassed its fail-closed rule")
                    time.sleep(.1)
                if len(received) != delivered or failures:
                    raise RuntimeError("HTTP bytes reached the origin while a fail-closed app was unavailable")

                def await_rewrites(target, expected):
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            result = exchange(target, b"revocation")
                            if result == expected: return
                        except (RuntimeError, ConnectionError):
                            if failures: raise
                        if time.monotonic() >= deadline: raise RuntimeError(f"Live permission change was not applied: {target!r}")
                        time.sleep(.02)

                subprocess.run([str(binary), "plugin", "untrust", "rewriter-second"], env=environment, check=True, capture_output=True, timeout=5)
                await_rewrites(b"/revoked-disabled", ((b"/revoked-disabled/a", b"revocation\0a"), 201, response_body + b"\0a"))
                subprocess.run([str(binary), "plugin", "trust", str(packages["packet-bridge"]), "--capability", "traffic.observe"], env=environment, check=True, capture_output=True, timeout=5)
                await_rewrites(b"/packet-check", ((b"/packet-check/a", b"revocation\0a"), 201, response_body + b"\0a"))
                subprocess.run([str(binary), "plugin", "trust", str(packages["packet-bridge"])], env=environment, check=True, capture_output=True, timeout=5)
                await_rewrites(b"/packet-check", ((b"/packet-check/a", b"revocation\0a"), 201, response_body + b"\0a"))
                subprocess.run([str(binary), "plugin", "untrust", "rewriter-first"], env=environment, check=True, capture_output=True, timeout=5)
                await_rewrites(b"/revoked-source-changed", ((b"/revoked-source-changed", b"revocation"), 200, response_body))

                observer_pid, _ = worker_process(runtime, 3)
                trust_path = root / "config/telar/trust.json"
                trust_path.write_text("invalid trust store")
                deadline = time.monotonic() + 5
                while True:
                    try:
                        os.kill(observer_pid, 0)
                    except ProcessLookupError:
                        break
                    if time.monotonic() >= deadline: raise RuntimeError("An invalid trust store kept an observation grant alive")
                    time.sleep(.02)

                print("Runtime Lua apps: digest grants, BPF/shared state, ordered binary/gzip HTTP edits, Desktop disconnect, cancellation, isolated recovery, fail-closed crashes, live revocation and invalid trust denial verified", flush=True)
            finally:
                if observer is not None and observer.poll() is None:
                    observer.terminate()
                    observer.wait(timeout=5)
                runtime.terminate()
                runtime.wait(timeout=10)
                done.set()
                worker.join(timeout=1)


if __name__ == "__main__":
    main()
