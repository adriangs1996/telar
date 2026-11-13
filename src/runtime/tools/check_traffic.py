#!/usr/bin/env python3
"""Exercise the actual C++ runtime, PCAP importer and Desktop Lua subscription."""

import argparse
import pathlib
import selectors
import struct
import subprocess
import tempfile
import time
import ssl
import hashlib
import contextlib
import socket
import threading
import os
import shutil
import traceback


@contextlib.contextmanager
def diagnostics_directory():
    root = pathlib.Path(tempfile.mkdtemp(prefix="telar-traffic-", dir="/tmp")).resolve()
    try:
        yield root
    except Exception:
        (root / "failure.log").write_text(traceback.format_exc())
        print(f"Traffic diagnostics preserved at {root}", flush=True)
        raise
    else:
        shutil.rmtree(root)


def echo_origin(listener, received, errors):
    try:
        for _ in range(2):
            connection, peer = listener.accept()
            with connection:
                connection.settimeout(10)
                body = bytearray()
                while True:
                    data = connection.recv(65536)
                    if not data: break
                    body.extend(data)
                received.append((peer[1], bytes(body)))
                connection.sendall(body)
    except Exception as error:
        errors.append(error)


def echo_exchange(destination, payload):
    with socket.create_connection(destination, timeout=10) as connection:
        port = connection.getsockname()[1]
        connection.sendall(payload)
        connection.shutdown(socket.SHUT_WR)
        response = bytearray()
        while True:
            data = connection.recv(65536)
            if not data: break
            response.extend(data)
        if response != payload:
            raise RuntimeError("Native control binary echo was changed or truncated")
    return port


def fixture(path, port=53535):
    payload = b"a\0b"
    ethernet = b"\0" * 12 + b"\x08\x00"
    udp = struct.pack("!HHHH", port, port, 8 + len(payload), 0) + payload
    ipv4 = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0,
                       b"\x7f\0\0\x01", b"\x7f\0\0\x01")
    packet = ethernet + ipv4 + udp
    write_pcap(path, [packet])


def write_pcap(path, packets):
    output = bytearray(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
    for index, packet in enumerate(packets):
        output.extend(struct.pack("<IIII", 123, 456 + index, len(packet), len(packet)))
        output.extend(packet)
    path.write_bytes(output)


def lua_bytes(value):
    return '"' + "".join(f"\\x{byte:02x}" for byte in value) + '"'


def fragments_fixture(path):
    packets, bodies = [], []
    for ipv6 in (False, True):
        body = (b"ipv6" if ipv6 else b"ipv4") + b"\0fragmented-binary-body"
        bodies.append(body)
        segment = struct.pack("!HHIIBBHHH", 50000, 80, 123, 0, 0x50, 0x10, 4096, 0, 0) + body
        for offset, length, more in ((24, len(segment) - 24, False), (0, 24, True)):
            payload = segment[offset:offset + length]
            if ipv6:
                fragment = struct.pack("!BBHI", 6, 0, offset | int(more), 77) + payload
                network = struct.pack("!IHBB16s16s", 6 << 28, len(fragment), 44, 64,
                                      socket.inet_pton(socket.AF_INET6, "::1"), socket.inet_pton(socket.AF_INET6, "::2")) + fragment
            else:
                network = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + length, 77, offset // 8 | (0x2000 if more else 0),
                                      64, 6, 0, socket.inet_aton("127.0.0.1"), socket.inet_aton("127.0.0.2")) + payload
            packets.append(b"\0" * 12 + (b"\x86\xdd" if ipv6 else b"\x08\x00") + network)
    invalid = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 45, 78, 0x2000, 64, 6, 0,
                          socket.inet_aton("127.0.0.1"), socket.inet_aton("127.0.0.2")) + segment[:25]
    packets.append(b"\0" * 12 + b"\x08\x00" + invalid)
    write_pcap(path, packets)
    return "local expected_packets = {" + ",".join(map(lua_bytes, packets)) + "}\nlocal expected_bodies = {" + ",".join(map(lua_bytes, bodies)) + "}\n"


def datagrams_fixture(path):
    packets, expected = [], []
    for ipv6 in (False, True):
        for icmp in (False, True):
            transport = "icmpv6" if icmp and ipv6 else "icmp" if icmp else "udp"
            body = (transport + ("6" if ipv6 else "4")).encode() + b"\0datagram-body"
            message = struct.pack("!BBHHH", 128 if ipv6 else 8, 0, 0, 22, 33) + body if icmp else struct.pack("!HHHH", 53535, 53, 8 + len(body), 0) + body
            protocol = (58 if ipv6 else 1) if icmp else 17
            if ipv6:
                for offset, fragment_body, more in ((16, message[16:], False), (0, message[:16], True)):
                    payload = struct.pack("!BBHI", protocol, 0, offset | int(more), 88 + int(icmp)) + fragment_body
                    network = struct.pack("!IHBB16s16s", 6 << 28, len(payload), 44, 64,
                                          socket.inet_pton(socket.AF_INET6, "::1"), socket.inet_pton(socket.AF_INET6, "::2")) + payload
                    packets.append(b"\0" * 12 + b"\x86\xdd" + network)
            else:
                network = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(message), 88 + int(icmp), 0, 64, protocol, 0,
                                      socket.inet_aton("127.0.0.1"), socket.inet_aton("127.0.0.2")) + message
                packets.append(b"\0" * 12 + b"\x08\x00" + network)
            expected.append("{transport='" + transport + "',ipv6=" + str(ipv6).lower() + ",bytes=" + lua_bytes(message if icmp else body) + "}")
    write_pcap(path, packets)
    return "local expected_packets = {" + ",".join(map(lua_bytes, packets)) + "}\nlocal expected_datagrams = {" + ",".join(expected) + "}\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--control", action="store_true", help="Also verify Lua network administration and private CA rotation without installing OS trust")
    modes.add_argument("--control-live", action="store_true", help="Verify Lua starts/stops root capture and PF redirect; first authorize sudo in this terminal")
    modes.add_argument("--fragments", action="store_true", help="Verify IPv4/IPv6 PCAP fragments and reconstructed binary TCP data reach Desktop Lua")
    modes.add_argument("--datagrams", action="store_true", help="Verify UDP/ICMP/ICMPv6 metadata, fragments, original packets and recorded datagrams through Desktop Lua")
    parser.add_argument("--domain-selection", action="store_true", help="With --control-live, resolve localhost through Lua administration before native redirection")
    options = parser.parse_args()
    if options.domain_selection and not options.control_live:
        parser.error("--domain-selection requires --control-live")
    runtime_binary = options.runtime.resolve()
    probe_binary = options.lua_probe.resolve()
    api = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode/ui/api.lua"

    with diagnostics_directory() as temporary, contextlib.ExitStack() as resources:
        root = pathlib.Path(temporary).resolve()
        endpoint = root / "runtime.sock"
        config = root / "config.lua"
        config.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,network_control=true,stream_interception=true,transparent_redirect=true,transparent_tls=true,intercept_hosts={},capture={enabled=false},ca_dir='ca'}}}\n" if options.control or options.control_live else "return {api_version=2,runtime={proxy={network_capture=true}}}\n")
        received, failures = [], []
        if options.control_live:
            udp = resources.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
            udp.bind(("127.0.0.1", 0))
            tcp = resources.enter_context(socket.socket())
            tcp.bind(("127.0.0.1", 0))
            tcp.listen()
            tcp.settimeout(30)
            origin = threading.Thread(target=echo_origin, args=(tcp, received, failures), daemon=True)
            origin.start()
        capture = root / "fixture.pcap"
        fragment_script = fragments_fixture(capture) if options.fragments else datagrams_fixture(capture) if options.datagrams else None
        if not options.fragments and not options.datagrams:
            fixture(capture)
        with (root / "runtime.log").open("w+") as log:
            runtime = subprocess.Popen([str(runtime_binary), "--socket", str(endpoint),
                                        "--config", str(config), "--history", ":memory:",
                                        "--no-session"], stdout=log, stderr=log)
            probe = None
            try:
                deadline = time.monotonic() + 10
                while not endpoint.exists():
                    if runtime.poll() is not None or time.monotonic() > deadline:
                        log.seek(0)
                        raise RuntimeError("Runtime did not start: " + log.read())
                    time.sleep(0.01)
                original = (root / "ca/ca-cert.pem").read_bytes() if options.control else None
                arguments = [str(probe_binary), str(endpoint), str(api)]
                if options.control:
                    arguments.append(str(api.parent.parent / "tests/traffic_control.lua"))
                if options.fragments or options.datagrams:
                    name = "traffic_fragments.lua" if options.fragments else "traffic_datagrams.lua"
                    script = root / name
                    script.write_text(fragment_script + (api.parent.parent / "tests" / name).read_text())
                    arguments.append(str(script))
                if options.control_live:
                    script = root / "control.lua"
                    host = "localhost" if options.domain_selection else "127.0.0.1"
                    script.write_text(f"local test_udp_port = {udp.getsockname()[1]}\nlocal test_tcp_port = {tcp.getsockname()[1]}\nlocal test_tcp_host = '{host}'\n" + (api.parent.parent / "tests/traffic_control_live.lua").read_text())
                    arguments.append(str(script))
                probe = subprocess.Popen(arguments,
                                         stdin=subprocess.PIPE if options.control_live else subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                         env={**os.environ, "TELAR_TRAFFIC_PROBE_TIMEOUT_MS": "30000" if options.control_live else "10000",
                                              **({"TELAR_TRAFFIC_PROBE_INPUT": "1"} if options.control_live else {})})
                with selectors.DefaultSelector() as selector:
                    selector.register(probe.stdout, selectors.EVENT_READ)
                    if not selector.select(20 if options.control_live else 10) or probe.stdout.readline().strip() != "ready":
                        probe.terminate()
                        output, errors = probe.communicate(timeout=5)
                        raise RuntimeError(f"Lua subscriber did not become ready: {output} {errors}")
                if options.control_live:
                    deadline = time.monotonic() + 15
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender, selectors.DefaultSelector() as selector:
                        selector.register(probe.stdout, selectors.EVENT_READ)
                        while True:
                            sender.sendto(b"a\0b", udp.getsockname())
                            if selector.select(0.1):
                                if probe.stdout.readline().strip() != "ready":
                                    raise RuntimeError("Lua redirect did not become ready")
                                break
                            if time.monotonic() >= deadline:
                                raise RuntimeError("Lua capture/redirect activation timed out")
                    redirected_payload = bytes(range(256)) * 256 + b"native\0control"
                    redirected_port = echo_exchange(tcp.getsockname(), redirected_payload)
                else:
                    subprocess.run([str(runtime_binary), "traffic", "import", "--socket", str(endpoint),
                                    "--file", str(capture)], check=True, timeout=10)
                output, errors = probe.communicate(input="c" if options.control_live else None, timeout=10)
                if probe.returncode != 0 or "packet verified" not in output:
                    raise RuntimeError(f"Lua packet delivery failed: {output} {errors}")
                if options.control:
                    current = (root / "ca/ca-cert.pem").read_bytes()
                    published = (root / "ca/ca-active-cert.pem").read_bytes()
                    if current == original or current != published:
                        raise RuntimeError("CA rotation did not update the persisted and active certificates")
                    digest = hashlib.sha256(ssl.PEM_cert_to_DER_cert(current.decode())).hexdigest()
                    if len(digest) != 64 or (root / "ca/trust-install.json").exists():
                        raise RuntimeError("Private CA check produced invalid metadata or installed system trust")
                if options.control_live:
                    direct_payload = b"direct\0after-cleanup"
                    direct_port = echo_exchange(tcp.getsockname(), direct_payload)
                    origin.join(timeout=2)
                    if origin.is_alive() or failures or len(received) != 2:
                        raise RuntimeError(f"Native control origin failed: {received}, {failures}")
                    if received[0][1] != redirected_payload or received[0][0] == redirected_port:
                        raise RuntimeError("Native Lua redirect was bypassed or changed binary data")
                    if received[1] != (direct_port, direct_payload):
                        raise RuntimeError("Direct connections were not restored after Lua redirect stop")
                if options.fragments:
                    print("Runtime -> Desktop Lua: original IPv4/IPv6 fragments, provenance, reconstructed binary TCP streams and explicit reconstruction errors verified")
                elif options.datagrams:
                    print("Runtime -> Desktop Lua: UDP/ICMP/ICMPv6 messages, IPv6 fragments, binary boundaries, original packets and recorded structured datagrams verified")
                elif options.control_live:
                    print("Desktop Lua: privileged capture start/stop, real packet, redirect activation, binary relay, cleanup and direct connections verified")
                elif options.control:
                    print("Runtime -> Desktop Lua: status, capture/redirect stop, private CA export/rotation, selection validation and cancellation verified")
                else:
                    print("Runtime -> Desktop Lua: binary packet, BPF filter and self-cancellation verified")
                if options.domain_selection:
                    print("Desktop Lua: DNS destination snapshot and native redirected binary relay verified")
            except Exception:
                if probe is not None:
                    if probe.poll() is None: probe.terminate()
                    output, errors = probe.communicate(timeout=5)
                    (root / "probe.stdout").write_text(output)
                    (root / "probe.stderr").write_text(errors)
                    if errors: print("Lua probe diagnostics:\n" + errors, file=sys.stderr, flush=True)
                raise
            finally:
                if probe is not None and probe.poll() is None:
                    probe.terminate()
                    probe.wait(timeout=5)
                runtime.terminate()
                try:
                    runtime.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    runtime.kill()
                    runtime.wait(timeout=5)
                    raise RuntimeError("Runtime did not finish native cleanup within ten seconds")
            if any(pathlib.Path(str(endpoint) + suffix).exists() for suffix in (".traffic", ".network", ".redirect")):
                raise RuntimeError("Traffic or administration socket was not cleaned up")


if __name__ == "__main__":
    main()
