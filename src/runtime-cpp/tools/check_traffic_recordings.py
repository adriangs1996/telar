#!/usr/bin/env python3
"""Verify runtime retention across Desktop reconnects and a PCAPNG round trip."""

import argparse
import json
import os
import pathlib
import re
import selectors
import subprocess
import socket
import threading
import time

from check_traffic import diagnostics_directory, fixture, datagrams_fixture
from check_traffic_hooks import read_http_message
from check_traffic_workers import receive_head


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    options = parser.parse_args()
    binary, probe = options.runtime.resolve(), options.lua_probe.resolve()
    api = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode/ui/api.lua"
    with diagnostics_directory() as root:
        endpoint = root / "runtime.sock"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update(XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"), XDG_RUNTIME_DIR=str(root / "run"), SHELL="/bin/sh")
        (root / "run").mkdir(mode=0o700)
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,anonymous_tunnels=true,intercept_hosts={},capture={enabled=true},ca_dir='ca'}}}")
        capture, exported = root / "fixture.pcap", root / "exported.pcapng"

        def run_probe(name, source):
            script = root / (name + ".lua")
            script.write_text(source)
            result = subprocess.run([str(probe), str(endpoint), str(api), str(script)], capture_output=True, text=True, env=environment, timeout=15)
            (root / (name + ".log")).write_text(result.stdout + result.stderr)
            if result.returncode or "packet verified" not in result.stdout:
                raise RuntimeError(f"Recording Lua probe {name} failed: {result.stdout} {result.stderr}")
            return result.stdout

        def import_capture(path):
            subprocess.run([str(binary), "traffic", "import", "--socket", str(endpoint), "--file", str(path)], env=environment, check=True, timeout=5, capture_output=True)

        with (root / "runtime.log").open("w+") as log:
            runtime = subprocess.Popen([str(binary), "--socket", str(endpoint), "--config", str(config), "--history", ":memory:", "--no-session"], stdout=log, stderr=log, env=environment)
            receiver = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic() >= deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: " + log.read())
                    time.sleep(.01)
                output = run_probe("start", """
local traffic = require('telar.traffic')
traffic.recordings.start({events={packet=true},filter='udp dst port 53535',max_bytes=4096,max_events=3,max_age_ms=60000},function(err,reply)
  assert(not err,err)
  assert(reply.result=='ok',reply.message)
  assert(not reply.administration_enabled and reply.recording.active)
  print('recording-id:'..reply.recording.id)
  test_done()
end)
""")
                identity = re.search(r"recording-id:(\d+)", output).group(1)
                fixture(capture, 53536)
                import_capture(capture)
                fixture(capture)
                for _ in range(4): import_capture(capture)
                source = "local expected_id=" + json.dumps(identity) + "\nlocal export_path=" + json.dumps(str(exported)) + "\n" + r'''
local traffic = require('telar.traffic')
local function checked(callback)
  return function(err,reply)
    assert(not err,err)
    assert(reply.result=='ok',reply.message)
    callback(reply)
  end
end
traffic.recordings.list(checked(function(reply)
  assert(#reply.recordings==1 and reply.recordings[1].id==expected_id)
  traffic.recordings.query({id=expected_id,cursor='1',limit=2},checked(function(reply)
    local page=reply.recording
    assert(page.gap and page.evicted=='1' and page.dropped=='0')
    assert(page.oldest_cursor=='2' and page.next_cursor=='4' and page.end_cursor=='5')
    assert(#page.events==2 and page.retained_bytes<=4096)
    for index,event in ipairs(page.events) do
      assert(event.recording_cursor==tostring(index+1))
      assert(event.kind=='packet' and event.interface=='offline' and event.link_type==1)
      assert(event.bytes:sub(-3)=='a\0b' and event.timestamp_us==123000456)
    end
    traffic.recordings.query({id=expected_id,cursor=page.next_cursor},checked(function(reply)
      assert(#reply.recording.events==1 and reply.recording.next_cursor==reply.recording.end_cursor)
      traffic.recordings.stop({id=expected_id},checked(function(reply)
        assert(not reply.recording.active)
        traffic.recordings.export({id=expected_id},checked(function(reply)
          local bytes=reply.recording.pcapng
          assert(bytes:sub(1,4)=='\x0a\x0d\x0d\x0a' and #bytes>28)
          require('telar.fs').write_file(export_path,bytes,function(err)
            assert(not err,err)
            test_done()
          end)
        end))
      end))
    end))
  end))
end))
'''
                run_probe("query", source)
                source = "local expected_id=" + json.dumps(identity) + "\n" + r'''
local traffic=require('telar.traffic')
traffic.recordings.remove({id=expected_id},function(err,reply)
  assert(not err and reply.result=='ok',err or reply.message)
  traffic.recordings.query({id=expected_id},function(err,reply)
    assert(not err and reply.result=='failed')
    traffic.recordings.list(function(err,reply)
      assert(not err and reply.result=='ok' and #reply.recordings==0)
      local count=0
      local stop
      stop=traffic.subscribe({events={packet=true},filter='udp dst port 53535'},function(err,event)
        assert(not err,err)
        if event.kind=='ready' then test_ready() end
        if event.kind=='packet' then
          assert(event.bytes:sub(-3)=='a\0b' and event.timestamp_us==123000456)
          count=count+1
          if count==3 then stop();test_done() end
        end
      end)
    end)
  end)
end)
'''
                script = root / "roundtrip.lua"
                script.write_text(source)
                receiver = subprocess.Popen([str(probe), str(endpoint), str(api), str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
                with selectors.DefaultSelector() as selector:
                    selector.register(receiver.stdout, selectors.EVENT_READ)
                    if not selector.select(10) or receiver.stdout.readline().strip() != "ready": raise RuntimeError("PCAPNG receiver did not become ready")
                import_capture(exported)
                output, errors = receiver.communicate(timeout=10)
                if receiver.returncode or "packet verified" not in output: raise RuntimeError(f"PCAPNG round trip failed: {output} {errors}")

                output = run_probe("http-start", """
require('telar.traffic').recordings.start({events={exchange=true,flow=true},host='127.0.0.1',max_bytes=65536,max_events=32},function(err,reply)
  assert(not err and reply.result=='ok',err or reply.message)
  print('recording-id:'..reply.recording.id)
  test_done()
end)
""")
                http_identity = re.search(r"recording-id:(\d+)", output).group(1)
                failures = []
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", 0))
                    listener.listen()
                    listener.settimeout(10)

                    def origin():
                        try:
                            connection, _ = listener.accept()
                            with connection:
                                connection.settimeout(10)
                                line, _, _, _ = read_http_message(connection)
                                if line != b"GET /retained HTTP/1.1\r\n": raise RuntimeError("Recorded request was changed")
                                connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nyes\0body")
                        except Exception as error:
                            failures.append(error)

                    worker = threading.Thread(target=origin, daemon=True)
                    worker.start()
                    port = int(next((root / "ca").glob("proxy-port-*")).read_text().splitlines()[0])
                    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
                        target = f"127.0.0.1:{listener.getsockname()[1]}"
                        client.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                        if not receive_head(client).startswith(b"HTTP/1.1 200 "): raise RuntimeError("Recorded HTTP CONNECT failed")
                        client.sendall(b"GET /retained HTTP/1.1\r\nHost: fixture.test\r\n\r\n")
                        client.shutdown(socket.SHUT_WR)
                        _, _, body, _ = read_http_message(client)
                        if body != b"yes\0body": raise RuntimeError("Recorded HTTP response was changed")
                    worker.join(timeout=5)
                    if worker.is_alive() or failures: raise RuntimeError(f"Recorded HTTP origin failed: {failures}")
                source = "local id=" + json.dumps(http_identity) + "\n" + r'''
local traffic=require('telar.traffic')
traffic.recordings.query({id=id,host='127.0.0.1'},function(err,reply)
  assert(not err and reply.result=='ok',err or reply.message)
  local flows={}
  local exchanges={}
  local opened,closed,binary=false,false,false
  for _,event in ipairs(reply.recording.events) do
    if event.kind=='flow.open' then flows[event.flow_id]=true;opened=true end
    if event.kind=='flow.close' then closed=true end
    if event.kind=='stream.data' and event.bytes:find('yes\0body',1,true) then binary=true end
    if event.kind=='exchange' then
      local exchange=event.exchange
      assert(exchange.method=='GET' and exchange.target=='/retained')
      assert(exchange.response.status==200 and exchange.response.body=='yes\0body')
      exchanges[#exchanges+1]=exchange
    end
  end
  if #exchanges>0 and opened and closed and binary then
    for _,exchange in ipairs(exchanges) do assert(flows[exchange.connection_id]) end
    print('captured-http')
  end
  test_done()
end)
'''
                deadline = time.monotonic() + 5
                while "captured-http" not in run_probe("http-query", source):
                    if time.monotonic() >= deadline: raise RuntimeError("HTTP/flow recording did not complete without a live subscriber")
                    time.sleep(.02)
                output = run_probe("datagram-start", """
require('telar.traffic').recordings.start({events={datagram=true},max_bytes=65536,max_events=8},function(err,reply)
  assert(not err and reply.result=='ok',err or reply.message)
  print('recording-id:'..reply.recording.id)
  test_done()
end)
""")
                datagram_identity = re.search(r"recording-id:(\d+)", output).group(1)
                expected = datagrams_fixture(capture)
                import_capture(capture)
                source = "local id=" + json.dumps(datagram_identity) + "\n" + expected + r'''
require('telar.traffic').recordings.query({id=id},function(err,reply)
  assert(not err and reply.result=='ok',err or reply.message)
  if #reply.recording.events==#expected_datagrams then
    for index,event in ipairs(reply.recording.events) do
      local expected=expected_datagrams[index]
      assert(event.kind=='datagram' and event.transport==expected.transport)
      assert(event.bytes==expected.bytes and event.ipv6==expected.ipv6 and not event.truncated)
      assert(event.offline and event.interface=='offline')
    end
    print('captured-datagrams')
  end
  test_done()
end)
'''
                deadline = time.monotonic() + 5
                while "captured-datagrams" not in run_probe("datagram-query", source):
                    if time.monotonic() >= deadline: raise RuntimeError("Datagram recording did not complete without a live subscriber")
                    time.sleep(.02)
                print("Runtime recordings -> Desktop Lua: BPF retention without a client, reconnect/list, eviction gaps, binary pages, stop/delete, stale identity, PCAPNG round trip and correlated HTTP/flow recording verified", flush=True)
                print("Runtime datagrams: UDP/ICMP/ICMPv6 reconstruction and recording without any live subscriber verified", flush=True)
            finally:
                if receiver is not None and receiver.poll() is None:
                    receiver.terminate()
                    receiver.wait(timeout=5)
                runtime.terminate()
                runtime.wait(timeout=10)


if __name__ == "__main__":
    main()
