#!/usr/bin/env python3
"""Verify actual runtime -> Desktop Lua hooks -> TCP forwarding without privileges."""

import argparse
import pathlib
import selectors
import socket
import subprocess
import tempfile
import shutil
import traceback
import threading
import time
import gzip
import http.client


def read_http_message(connection):
    with connection.makefile("rb") as source:
        line = source.readline(65537)
        headers = {}
        while True:
            field = source.readline(65537)
            if field == b"\r\n": break
            if not field or len(field) > 65536: raise RuntimeError("Invalid HTTP test head")
            name, value = field.split(b":", 1)
            headers[name.lower()] = value.strip()
        trailers = {}
        if headers.get(b"transfer-encoding") == b"chunked":
            chunks = []
            while True:
                length = int(source.readline(1025).split(b";", 1)[0], 16)
                if length == 0: break
                chunks.append(source.read(length))
                if source.read(2) != b"\r\n": raise RuntimeError("Invalid HTTP test chunk")
            while True:
                field = source.readline(65537)
                if field == b"\r\n": break
                if not field: raise RuntimeError("Incomplete HTTP test trailers")
                name, value = field.split(b":", 1)
                trailers[name.lower()] = value.strip()
            body = b"".join(chunks)
        else:
            body = source.read(int(headers.get(b"content-length", b"0")))
    return line, headers, body, trailers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--http", action="store_true", help="Verify HTTP capture, including a fragmented request line, instead of byte rewriting")
    modes.add_argument("--http-edit", action="store_true", help="Verify composed semantic HTTP edits with compressed binary bodies larger than a packet frame")
    modes.add_argument("--http2-edit", action="store_true", help="Verify HTTP/2 editing, independent stream pauses, PING and trailers; requires Python h2")
    options = parser.parse_args()
    if options.http2_edit:
        try:
            import network_h2
        except ImportError:
            parser.error("HTTP/2 checks require h2; install tools/requirements-network.txt in a test virtual environment")
    desktop = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode"
    root = pathlib.Path(tempfile.mkdtemp(prefix="tlr-hooks-", dir="/tmp")).resolve()
    with socket.socket() as origin:
        endpoint = root / "runtime.sock"
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,stream_interception=true,anonymous_tunnels=true,intercept_hosts={},capture={enabled=true},ca_dir='ca'}}}\n")
        origin.bind(("127.0.0.1", 0))
        origin.listen()
        received = bytearray()
        errors = []
        edit_body = bytes(range(256)) * 2048
        edit_response = b"origin\0" + bytes(range(256)) * 1536

        def receive():
            try:
                origin.settimeout(10)
                connection, _ = origin.accept()
                with connection:
                    connection.settimeout(10)
                    if options.http2_edit:
                        received.extend(network_h2.serve(connection))
                        return
                    if options.http_edit:
                        line, headers, body, trailers = read_http_message(connection)
                        received.extend(gzip.decompress(body))
                        if line != b"POST /edited HTTP/1.1\r\n" or headers.get(b"x-telar-request") != b"yes" or trailers.get(b"x-client") != b"fixture":
                            raise RuntimeError("Structured request edits or trailers were lost")
                        encoded = gzip.compress(edit_response)
                        connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: " + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
                        return
                    while data := connection.recv(65536):
                        received.extend(data)
                        if options.http and received.endswith(b"\r\n\r\n"): break
                    connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nyes\0body" if options.http else b"done")
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=receive, daemon=True)
        worker.start()
        with (root / "runtime.log").open("w+") as log:
            runtime = subprocess.Popen([str(options.runtime.resolve()), "--socket", str(endpoint), "--config", str(config), "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            probe = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: " + log.read())
                    time.sleep(0.01)
                script = "tests/traffic_http2_edit.lua" if options.http2_edit else "tests/traffic_http_edit.lua" if options.http_edit else "tests/traffic_http.lua" if options.http else "tests/traffic_hooks.lua"
                probe = subprocess.Popen([str(options.lua_probe.resolve()), str(endpoint), str(desktop / "ui/api.lua"), str(desktop / script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                with selectors.DefaultSelector() as selector:
                    selector.register(probe.stdout, selectors.EVENT_READ)
                    if not selector.select(10) or probe.stdout.readline().strip() != "ready":
                        raise RuntimeError("Lua hook did not register")
                # Runtime prints its public proxy port through the existing metadata file.
                port_files = list((root / "ca").glob("proxy-port-*"))
                if len(port_files) != 1:
                    raise RuntimeError("Proxy port metadata is unavailable: " + str(list((root / 'ca').iterdir())))
                port = int(port_files[0].read_text().splitlines()[0])
                with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
                    target = f"127.0.0.1:{origin.getsockname()[1]}"
                    client.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                    response = bytearray()
                    while not response.endswith(b"\r\n\r\n"):
                        part = client.recv(1)
                        if not part:
                            raise RuntimeError(f"CONNECT response ended early; runtime status: {runtime.poll()}")
                        response.extend(part)
                    if not response.startswith(b"HTTP/1.1 200 "):
                        raise RuntimeError("CONNECT rejected: " + repr(response))
                    payload = b"GET /plain HTTP/1.1\r\nHost: fixture.test\r\n\r\n" if options.http else bytes(range(256)) * 16
                    if options.http_edit:
                        encoded = gzip.compress(edit_body)
                        payload = b"POST /original HTTP/1.1\r\nHost: fixture.test\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n" + f"{len(encoded):x}\r\n".encode() + encoded + b"\r\n0\r\nX-Client: fixture\r\n\r\n"
                    if options.http2_edit:
                        network_h2.exchange(client)
                    elif options.http or options.http_edit:
                        client.sendall(payload[:1])
                        time.sleep(0.005)
                        client.sendall(payload[1:])
                    else:
                        client.sendall(payload)
                    client.shutdown(socket.SHUT_WR)
                    if options.http2_edit:
                        response = expected_response = b"done"
                    elif options.http_edit:
                        result = http.client.HTTPResponse(client)
                        result.begin()
                        if result.status != 201 or result.getheader("X-Telar-Response") != "yes" or result.getheader("Transfer-Encoding") != "chunked":
                            raise RuntimeError("Structured response edits were lost")
                        response = gzip.decompress(result.read())
                        expected_response = b"res\0" + edit_response + b"\0end"
                    else:
                        expected_response = b"HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nyes\0body" if options.http else b"done"
                        response = bytearray()
                        while len(response) < len(expected_response):
                            part = client.recv(len(expected_response) - len(response))
                            if not part: break
                            response.extend(part)
                    if response != expected_response:
                        detail = ""
                        if probe.poll() is not None:
                            output, detail = probe.communicate(timeout=1)
                        raise RuntimeError(f"Half-close response was lost: {response!r}, origin={len(received)}, probe={probe.poll()}, {detail}")
                worker.join(timeout=5)
                if errors:
                    raise errors[0]
                expected = b"verified" if options.http2_edit else b"req\0" + edit_body + b"\0end" if options.http_edit else payload if options.http else b"".join(bytes([byte, byte]) for byte in payload)
                if received != expected:
                    raise RuntimeError(f"Lua replacement differed: {len(received)} != {len(expected)}")
                output, error = probe.communicate(timeout=12)
                if probe.returncode != 0 or "packet verified" not in output:
                    raise RuntimeError(f"Lua hook/flow verification failed: {output} {error}")
                print("Desktop Lua: HTTP/2 independent stream pauses, PING, composed large binary edits, gzip and trailers verified" if options.http2_edit else "Desktop Lua: composed HTTP request/response edits, large binary bodies, gzip, chunking and trailers verified" if options.http_edit else "Desktop Lua: cleartext HTTP, fragmented request line, headers and binary response body verified" if options.http else "Desktop Lua: ordered hooks, composed binary replacement, stream offsets, half-close and cancellation verified")
            except Exception:
                (root / "failure.log").write_text(traceback.format_exc())
                print(f"Hook diagnostics preserved at {root}; runtime status: {runtime.poll()}")
                if probe is not None:
                    if probe.poll() is None: probe.terminate()
                    output, error = probe.communicate(timeout=5)
                    (root / "probe.stdout").write_text(output)
                    (root / "probe.stderr").write_text(error)
                (root / "origin.log").write_text(f"Received {len(received)} bytes; errors: {errors}")
                raise
            finally:
                if probe is not None and probe.poll() is None:
                    probe.terminate()
                    probe.wait(timeout=5)
                if runtime.poll() is None: runtime.terminate()
                runtime.wait(timeout=5)
    shutil.rmtree(root)


if __name__ == "__main__":
    main()
