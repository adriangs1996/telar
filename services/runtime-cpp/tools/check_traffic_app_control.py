#!/usr/bin/env python3
"""Verify package-scoped control and recording through actual runtime Lua workers."""

import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import signal
import socket
import ssl
import subprocess
import threading
import time

from check_plugin_startup import package
from check_traffic import diagnostics_directory, fixture
from check_traffic_hooks import read_http_message
from check_traffic_workers import receive_head, worker_process


RECORDER = r'''
local traffic=require('telar.traffic')
local own
local failure
local function checked(callback)
  return function(err,reply)
    if err or reply.result~='ok' then failure=err or reply.message end
    assert(not err,err)
    assert(reply.result=='ok',reply.message)
    callback(reply)
  end
end
for _,operation in ipairs({traffic.capture.stop,traffic.ca.rotate}) do
  local allowed,message=pcall(function() operation(function() end) end)
  assert(not allowed and message:find('capability denied'))
end
local cancel=traffic.status(function() error('Cancelled status callback ran') end)
cancel()
traffic.status(checked(function(reply) assert(not reply.administration_enabled) end))
for index=1,5 do traffic.status(checked(function(reply) assert(not reply.administration_enabled) end)) end
traffic.recordings.list(checked(function(reply)
  assert(#reply.recordings<=1)
  if #reply.recordings==1 then own=reply.recordings[1].id;return end
  traffic.recordings.start({events={packet=true},filter='udp dst port 53535',max_bytes=4096,max_events=3,max_age_ms=60000},checked(function(reply) own=reply.recording.id end))
end))
traffic.intercept({stage='http',host='127.0.0.1',direction='outbound',failure='reject',timeout_ms=2500},function(err,event)
  assert(not err,err)
  if event.kind~='http.intercept.request' then return end
  local mode,id=event.message.target:match('^/'..label..'/([^/]+)/?(%d*)$')
  if not mode then return {action='allow'} end
  if not own then return {action='replace',body='pending:'..(failure or 'waiting')} end
  if mode=='info' then
    traffic.recordings.query({id=own},checked(function(reply)
      for _,packet in ipairs(reply.recording.events) do
        assert(packet.kind=='packet' and packet.bytes:sub(-3)=='a\0b')
        assert(packet.captured_bytes==#packet.bytes and packet.offline)
      end
      event.respond({action='replace',body=own..':'..#reply.recording.events})
    end))
  elseif mode=='list' then
    traffic.recordings.list(checked(function(reply)
      assert(#reply.recordings==1 and reply.recordings[1].id==own)
      event.respond({action='replace',body='own-only'})
    end))
  else
    local operation=assert(traffic.recordings[mode])
    operation({id=id},function(err,reply)
      assert(not err and reply.result=='failed' and reply.recording==nil)
      event.respond({action='replace',body='foreign-denied'})
    end)
  end
end)
return {}
'''

ADMIN = r'''
local traffic=require('telar.traffic')
local fingerprint
local function checked(callback)
  return function(err,reply)
    assert(not err,err)
    assert(reply.result=='ok',reply.message)
    callback(reply)
  end
end
local allowed,message=pcall(function() traffic.recordings.list(function() end) end)
assert(not allowed and message:find('capability denied'))
traffic.status(checked(function(reply)
  assert(reply.administration_enabled)
  traffic.capture.stop(checked(function()
    traffic.ca.certificate(checked(function(original)
      traffic.ca.rotate(checked(function()
        traffic.ca.certificate(checked(function(updated)
          assert(updated.ca.fingerprint_sha256~=original.ca.fingerprint_sha256)
          assert(updated.ca.certificate:find('-----BEGIN CERTIFICATE-----',1,true))
          fingerprint=updated.ca.fingerprint_sha256
        end))
      end))
    end))
  end))
end))
traffic.intercept({stage='http',host='127.0.0.1',direction='outbound',failure='reject'},function(err,event)
  assert(not err,err)
  if event.kind~='http.intercept.request' then return end
  if event.message.target=='/admin' then return {action='replace',body=fingerprint or 'pending'} end
  return {action='allow'}
end)
return {}
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    options=parser.parse_args()
    binary,probe=options.runtime.resolve(),options.lua_probe.resolve()
    api=pathlib.Path(__file__).resolve().parents[2]/"desktop-mode/ui/api.lua"
    with diagnostics_directory() as root, contextlib.ExitStack() as resources:
        environment={key:value for key,value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update(XDG_CONFIG_HOME=str(root/"config"),XDG_DATA_HOME=str(root/"data"),XDG_CACHE_HOME=str(root/"cache"),XDG_STATE_HOME=str(root/"state"),XDG_RUNTIME_DIR=str(root/"run"),SHELL="/bin/sh")
        (root/"run").mkdir(mode=0o700)
        configured=[]
        for name,source,capabilities in (("alpha","local label='alpha'\n"+RECORDER,["traffic.record","traffic.intercept"]),("beta","local label='beta'\n"+RECORDER,["traffic.record","traffic.intercept"]),("admin",ADMIN,["traffic.control","traffic.intercept"])):
            directory=package(root,name,capabilities=capabilities)
            (directory/"main.lua").write_text(source)
            subprocess.run([str(binary),"plugin","trust",str(directory)],env=environment,capture_output=True,check=True,timeout=5)
            configured.append("{path="+json.dumps(str(directory))+"}")
        config=root/"config.lua"
        config.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,network_control=true,stream_interception=true,anonymous_tunnels=true,intercept_hosts={},capture={enabled=false},ca_dir='ca'}},plugins={"+",".join(configured)+"}}")
        endpoint=root/"runtime.sock"
        listener=resources.enter_context(socket.socket())
        listener.bind(("127.0.0.1",0))
        listener.listen()
        listener.settimeout(.1)
        stopped=threading.Event()
        failures=[]

        def origin():
            while not stopped.is_set():
                try: connection,_=listener.accept()
                except socket.timeout: continue
                try:
                    with connection:
                        connection.settimeout(10)
                        if not connection.recv(1,socket.MSG_PEEK): continue
                        _,_,body,_=read_http_message(connection)
                        connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: "+str(len(body)).encode()+b"\r\n\r\n"+body)
                except Exception as error:
                    failures.append(error)
                    return

        origin_worker=threading.Thread(target=origin,daemon=True)
        origin_worker.start()
        with (root/"runtime.log").open("w+") as log:
            runtime=subprocess.Popen([str(binary),"--socket",str(endpoint),"--config",str(config),"--history",":memory:","--no-session"],env=environment,stdout=log,stderr=log)
            try:
                deadline=time.monotonic()+10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic()>=deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: "+log.read())
                    time.sleep(.01)
                port=int(next((root/"ca").glob("proxy-port-*")).read_text().splitlines()[0])

                def exchange(path):
                    with socket.create_connection(("127.0.0.1",port),timeout=10) as client:
                        target=f"127.0.0.1:{listener.getsockname()[1]}"
                        client.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                        if not receive_head(client).startswith(b"HTTP/1.1 200 "): raise RuntimeError("Control fixture CONNECT failed")
                        client.sendall(b"POST "+path.encode()+b" HTTP/1.1\r\nHost: fixture.test\r\nContent-Length: 5\r\n\r\nprobe")
                        _,_,body,_=read_http_message(client)
                        return body.decode()

                def await_body(path,predicate):
                    deadline=time.monotonic()+10
                    detail="no response"
                    while True:
                        try:
                            body=exchange(path)
                            detail=repr(body)
                            if predicate(body): return body
                        except (RuntimeError,OSError) as error:
                            detail=repr(error)
                            if failures: raise
                        if time.monotonic()>=deadline: raise RuntimeError(f"Package control did not become ready: {path}; last={detail}")
                        time.sleep(.02)

                alpha=await_body("/alpha/info",lambda body:body.endswith(":0")).split(":")[0]
                beta=await_body("/beta/info",lambda body:body.endswith(":0")).split(":")[0]
                if alpha==beta: raise RuntimeError("Two packages received the same recording identity")
                fingerprint=await_body("/admin",lambda body:len(body)==64)
                public=(root/"ca/ca-active-cert.pem").read_text()
                if hashlib.sha256(ssl.PEM_cert_to_DER_cert(public)).hexdigest()!=fingerprint.lower(): raise RuntimeError(f"Package CA rotation did not replace the runtime signer: callback={fingerprint}")
                capture=root/"fixture.pcap"
                fixture(capture)
                for _ in range(4): subprocess.run([str(binary),"traffic","import","--socket",str(endpoint),"--file",str(capture)],env=environment,capture_output=True,check=True,timeout=5)
                for label,identity,foreign in (("alpha",alpha,beta),("beta",beta,alpha)):
                    await_body(f"/{label}/info",lambda body:body==identity+":3")
                    if exchange(f"/{label}/list")!="own-only": raise RuntimeError("A package listed another package's recording")
                    for operation in ("query","stop","remove","export"):
                        if exchange(f"/{label}/{operation}/{foreign}")!="foreign-denied": raise RuntimeError("A package accessed another package's recording")
                child,_=worker_process(runtime,0)
                os.kill(child,signal.SIGKILL)
                await_body("/alpha/info",lambda body:body==alpha+":3")
                subprocess.run([str(binary),"plugin","untrust","alpha"],env=environment,capture_output=True,check=True,timeout=5)
                await_body("/alpha/info",lambda body:body=="probe")
                await_body("/beta/info",lambda body:body==beta+":3")
                script=root/"desktop.lua"
                script.write_text("local alpha="+json.dumps(alpha)+"\nlocal beta="+json.dumps(beta)+"\n"+r'''
local traffic=require('telar.traffic')
traffic.recordings.list(function(err,reply)
  assert(not err and reply.result=='ok' and #reply.recordings==2)
  for _,recording in ipairs(reply.recordings) do
    assert(recording.active==(recording.id==beta))
  end
  traffic.recordings.query({id=alpha},function(err,reply)
    assert(not err and reply.result=='ok' and #reply.recording.events==3)
    test_done()
  end)
end)
''')
                desktop=subprocess.run([str(probe),str(endpoint),str(api),str(script)],env=environment,capture_output=True,text=True,timeout=15)
                if desktop.returncode or "packet verified" not in desktop.stdout: raise RuntimeError(f"Account recovery after app revocation failed: {desktop.stdout} {desktop.stderr}")
                if failures: raise RuntimeError(f"Control fixture origin failed: {failures}")
                print("Runtime Lua apps: scoped recording/control grants, private CA rotation, async HTTP decisions, cross-package denial, recording recovery after worker crash and revocation verified",flush=True)
            finally:
                runtime.terminate()
                runtime.wait(timeout=10)
                stopped.set()
                origin_worker.join(timeout=1)


if __name__=="__main__":
    main()
