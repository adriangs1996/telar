import http.client
from contextlib import closing
from concurrent.futures import ThreadPoolExecutor
import json
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from ipv6_extensions import exercise_ipv6_extensions

TUN_INTERFACE = "teltun1"
TUN_ADDRESS = "192.0.2.1"
HTTP_PORT = 8080
HTTPS_PORT = 8443
UDP_PORT = 5353
TCP_STREAM_PORT = 9090
TCP_PENDING_SOURCE_PORT = 45873
TEST_TIMEOUT = 10
SENTINEL_TABLE = "telar_test_sentinel"


def command(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode:
        raise AssertionError(f"{' '.join(args)} failed:\n{result.stdout}{result.stderr}")
    return result


def get_route(destination):
    return json.loads(command("ip", "-j", "-4", "route", "get", destination).stdout)[0]


def http_request(destination):
    with closing(http.client.HTTPConnection(destination, HTTP_PORT, timeout=TEST_TIMEOUT)) as connection:
        connection.request("GET", "/")
        response = connection.getresponse()
        assert response.status == 200
        return json.loads(response.read())


def tls_request(destination, hostname, inspected=True):
    authority = "inspection" if inspected else "origin"
    context = ssl.create_default_context(cafile=f"/tests/tls-fixtures/{authority}-ca.pem")
    context.set_alpn_protocols(["h2", "http/1.1"])
    with socket.create_connection((destination, HTTPS_PORT), timeout=TEST_TIMEOUT) as raw:
        with context.wrap_socket(raw, server_hostname=hostname) as secured:
            assert secured.selected_alpn_protocol() == "http/1.1"
            original = ssl.PEM_cert_to_DER_cert(Path("/tests/tls-fixtures/server.pem").read_text())
            assert (secured.getpeercert(binary_form=True) != original) == inspected
            with closing(http.client.HTTPConnection(destination, HTTPS_PORT, timeout=TEST_TIMEOUT)) as connection:
                connection.sock = secured
                connection.request("GET", "/", headers={"Host": hostname})
                response = connection.getresponse()
                assert response.status == 200
                return json.loads(response.read())


def exercise_tls(destinations, sources):
    with tempfile.TemporaryDirectory(prefix="telar-proxy-tls-") as scratch:
        log = Path(scratch) / "proxy.log"
        for scope in ("proxy.test", "*"):
            with log.open("w") as stream:
                proxy = subprocess.Popen([
                    "telar-proxy", "-all", "-inspect-host", scope,
                    "-tls-ca-cert", "/tests/tls-fixtures/inspection-ca.pem",
                    "-tls-ca-key", "/tests/tls-fixtures/inspection-key.pem",
                    "-tls-upstream-ca", "/tests/tls-fixtures/origin-ca.pem",
                ], stdout=stream, stderr=stream)
                try:
                    wait_ready(proxy, log)
                    for destination, source in zip(destinations, sources):
                        assert tls_request(destination, "proxy.test") == {"peer": source, "payload": "tcp-ok"}
                        assert tls_request(destination, "bypass.test", inspected=scope == "*") == {"peer": source, "payload": "tcp-ok"}
                        if scope == "*":
                            assert tls_request(destination, destination) == {"peer": source, "payload": "tcp-ok"}
                        assert http_request(destination) == {"peer": source, "payload": "tcp-ok"}
                    assert 'Inspecting TLS host=proxy.test protocol="http/1.1"' in log.read_text()
                    proxy.terminate()
                    assert proxy.wait(timeout=TEST_TIMEOUT) == 0, log.read_text()
                    for family in ("ip", "ip6"):
                        assert command("nft", "list", "table", family, f"telar_proxy_{proxy.pid}", check=False).returncode != 0
                    assert command("ip", "link", "show", TUN_INTERFACE, check=False).returncode != 0
                    print(f"TLS scope {scope}: IPv4/IPv6 HTTPS, verified certificates, ALPN, passthrough, plain HTTP and cleanup passed", flush=True)
                finally:
                    if proxy.poll() is None:
                        proxy.terminate()
                        proxy.wait(timeout=TEST_TIMEOUT)
                    print(log.read_text(), flush=True)


def exercise_tcp_stream(destination, source):
    payload = b"tcp-stream-data-" * 131072
    with socket.create_connection((destination, TCP_STREAM_PORT), timeout=TEST_TIMEOUT) as connection:
        assert connection.getsockname()[0] == (TUN_ADDRESS6 if ":" in destination else TUN_ADDRESS)
        connection.sendall(payload)
        connection.shutdown(socket.SHUT_WR)
        with connection.makefile("rb") as response:
            metadata = json.loads(response.readline())
            assert metadata == {"peer": source, "size": len(payload)}, metadata
            assert response.read() == payload[::-1], "TCP relay changed stream bytes or truncated the response after FIN"
    with ThreadPoolExecutor(max_workers=4) as pool:
        replies = list(pool.map(http_request, [destination] * 4))
    assert all(reply == {"peer": source, "payload": "tcp-ok"} for reply in replies)
    try:
        with socket.create_connection((destination, TCP_STREAM_PORT + 1), timeout=TEST_TIMEOUT):
            raise AssertionError("closed origin port unexpectedly accepted a connection")
    except ConnectionRefusedError:
        pass
    print(f"{destination}: TCP 2 MiB each way, half-close, concurrent connections and refused origin passed", flush=True)


def assert_tcp_handler(log, destination):
    target = f"[{destination}]" if ":" in destination else destination
    assert f"to {target}:{HTTP_PORT} through " in log.read_text(), "TCP traffic did not use the socket relay"


def pending_tcp_handshake(destination, table):
    # Send a SYN without a kernel TCP socket. Suppress its automatic RST so
    # netstack stays in SYN-RCVD until service shutdown aborts the handshake.
    rules = f'''create table ip {table}
add chain ip {table} output {{ type filter hook output priority filter; policy accept; }}
add rule ip {table} output oifname "{TUN_INTERFACE}" ip saddr {TUN_ADDRESS} ip daddr {destination} tcp sport {TCP_PENDING_SOURCE_PORT} tcp flags & rst == rst drop
'''
    subprocess.run(["nft", "-f", "-"], input=rules, text=True, check=True)
    header = struct.pack("!HHIIBBHHH", TCP_PENDING_SOURCE_PORT, TCP_STREAM_PORT, 12345, 0, 5 << 4, 2, 65535, 0, 0)
    pseudo = socket.inet_aton(TUN_ADDRESS) + socket.inet_aton(destination) + struct.pack("!BBH", 0, socket.IPPROTO_TCP, len(header))
    checksum = sum(struct.unpack("!16H", pseudo + header))
    while checksum >> 16:
        checksum = (checksum & 65535) + (checksum >> 16)
    header = header[:16] + struct.pack("!H", (~checksum) & 65535) + header[18:]
    connection = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
    try:
        connection.bind((TUN_ADDRESS, 0))
        connection.settimeout(TEST_TIMEOUT)
        connection.sendto(header, (destination, TCP_STREAM_PORT))
        deadline = time.monotonic() + TEST_TIMEOUT
        while time.monotonic() < deadline:
            packet, peer = connection.recvfrom(4096)
            offset = (packet[0] & 15) * 4
            if peer[0] == destination and packet[offset + 13] & 18 == 18:
                print("Pending TCP handshake: received SYN-ACK without completing it", flush=True)
                return connection
        raise AssertionError("no SYN-ACK for the pending TCP handshake")
    except BaseException:
        connection.close()
        command("nft", "delete", "table", "ip", table, check=False)
        raise


def wait_ready(proxy, log):
    deadline = time.monotonic() + TEST_TIMEOUT
    while time.monotonic() < deadline:
        text = log.read_text()
        if "Capture ready" in text:
            return
        if proxy.poll() is not None:
            raise AssertionError(f"proxy exited during startup:\n{text}")
        time.sleep(0.05)
    raise AssertionError(f"proxy did not activate:\n{log.read_text()}")


def check_cleanup(destination, original_route, sentinel, table):
    assert command("nft", "list", "table", "ip", table, check=False).returncode != 0
    assert command("nft", "list", "table", "ip", SENTINEL_TABLE).stdout == sentinel
    route = get_route(destination)
    assert route["dev"] == original_route["dev"], route
    assert route["prefsrc"] == original_route["prefsrc"], route
    assert command("ip", "link", "show", TUN_INTERFACE, check=False).returncode != 0
    states = command("conntrack", "-L", "-f", "ipv4", "-s", TUN_ADDRESS, "-d", destination)
    assert not states.stdout.strip(), states.stdout


def exercise_forwarding(destination, outbound_address):
    route = get_route(destination)
    assert route["dev"] == TUN_INTERFACE, route
    assert route["prefsrc"] == TUN_ADDRESS, route
    ping = command("ping", "-c", "3", "-W", "2", destination)
    assert "0% packet loss" in ping.stdout, ping.stdout
    print(f"{destination}: ICMP 3/3 replies through TUN", flush=True)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(TEST_TIMEOUT)
        client.connect((destination, UDP_PORT))
        assert client.getsockname()[0] == TUN_ADDRESS
        client.send(b"udp-ok")
        reply = json.loads(client.recv(4096))
        assert reply == {"peer": outbound_address, "payload": "udp-ok"}, reply
    print(f"{destination}: UDP response with translated source", flush=True)

    reply = http_request(destination)
    assert reply == {"peer": outbound_address, "payload": "tcp-ok"}, reply
    exercise_tcp_stream(destination, outbound_address)
    print(f"{destination}: TCP response through the socket relay", flush=True)


def exercise(destination):
    original_route = get_route(destination)
    outbound_address = original_route["prefsrc"]
    assert http_request(destination)["peer"] == outbound_address
    command("nft", "add", "table", "ip", SENTINEL_TABLE)
    sentinel = command("nft", "list", "table", "ip", SENTINEL_TABLE).stdout

    direct_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    direct_udp.settimeout(TEST_TIMEOUT)
    direct_udp.bind((outbound_address, 0))
    direct_udp.connect((destination, UDP_PORT))
    direct_udp.send(b"unrelated-flow")
    assert json.loads(direct_udp.recv(4096))["peer"] == outbound_address
    direct_port = str(direct_udp.getsockname()[1])

    with tempfile.TemporaryDirectory(prefix="telar-proxy-test-") as scratch:
        log = Path(scratch) / "proxy.log"
        with log.open("w") as stream:
            for stop_signal in (signal.SIGTERM, signal.SIGINT):
                proxy = subprocess.Popen(["telar-proxy", "-route", destination], stdout=stream, stderr=stream)
                table = f"telar_proxy_{proxy.pid}"
                try:
                    wait_ready(proxy, log)
                    exercise_forwarding(destination, outbound_address)
                    assert_tcp_handler(log, destination)

                    # Keep a connection idle while the service shuts down.
                    idle = socket.create_connection((destination, TCP_STREAM_PORT), timeout=TEST_TIMEOUT)
                    pending_table = f"telar_test_handshake_{proxy.pid}"
                    pending = pending_tcp_handshake(destination, pending_table)

                    rules = json.loads(command("nft", "-j", "list", "table", "ip", table).stdout)
                    nat_packets = sum(
                        expression["counter"]["packets"]
                        for item in rules["nftables"]
                        if item.get("rule", {}).get("chain") == "outbound_nat"
                        for expression in item["rule"]["expr"]
                        if "counter" in expression
                    )
                    # ICMP and UDP still use NAT; TCP now uses a separate socket.
                    assert nat_packets >= 2, rules
                    assert "protocol=ICMP source=192.0.2.1" in log.read_text()

                    proxy.send_signal(stop_signal)
                    assert proxy.wait(timeout=TEST_TIMEOUT) == 0, log.read_text()
                    idle.close()
                    pending.close()
                    command("nft", "delete", "table", "ip", pending_table)
                    print("Shutdown joined both an idle TCP relay and an incomplete handshake", flush=True)
                    check_cleanup(destination, original_route, sentinel, table)
                    preserved = command("conntrack", "-L", "-p", "udp", "-s", outbound_address,
                                        "-d", destination, "--sport", direct_port)
                    assert preserved.stdout.strip(), "cleanup removed an unrelated connection"
                    assert http_request(destination)["peer"] == outbound_address
                    print(f"{stop_signal.name}: route, TUN, NAT and states removed; unrelated rules and connections preserved", flush=True)
                finally:
                    if proxy.poll() is None:
                        proxy.terminate()
                        try:
                            proxy.wait(timeout=TEST_TIMEOUT)
                        except subprocess.TimeoutExpired:
                            proxy.kill()
                            proxy.wait()
                    print(log.read_text(), flush=True)
                    stream.seek(0)
                    stream.truncate()

            # A failed route insertion must not delete the pre-existing route.
            prefix = destination + "/32"
            command("ip", "-4", "route", "add", prefix, "dev", original_route["dev"],
                    "src", outbound_address, "proto", "static")
            previous = command("ip", "-j", "-4", "route", "show", "exact", prefix).stdout
            proxy = subprocess.Popen(["telar-proxy", "-route", destination], stdout=stream, stderr=stream)
            try:
                assert proxy.wait(timeout=TEST_TIMEOUT) == 1, log.read_text()
                assert "File exists" in log.read_text(), log.read_text()
                check_cleanup(destination, original_route, sentinel, f"telar_proxy_{proxy.pid}")
                assert command("ip", "-j", "-4", "route", "show", "exact", prefix).stdout == previous
                assert http_request(destination)["peer"] == outbound_address
                print("Startup rollback: existing route preserved; temporary TUN and NAT removed", flush=True)
            finally:
                if proxy.poll() is None:
                    proxy.terminate()
                    proxy.wait(timeout=TEST_TIMEOUT)
                command("ip", "-4", "route", "del", prefix, "dev", original_route["dev"])
                print(log.read_text(), flush=True)

    direct_udp.close()


def exercise_all(gateway, destinations):
    outbound = get_route(gateway)
    interface = outbound["dev"]
    source = outbound["prefsrc"]
    # The peer owns addresses in both halves of IPv4. Making it the default
    # gateway exercises default routing instead of overriding connected routes.
    command("ip", "-4", "route", "replace", "default", "via", gateway, "dev", interface)
    default_route = command("ip", "-j", "-4", "route", "show", "default").stdout
    for destination in destinations:
        assert http_request(destination)["peer"] == source
    sentinel = command("nft", "list", "table", "ip", SENTINEL_TABLE).stdout

    with tempfile.TemporaryDirectory(prefix="telar-proxy-all-") as scratch:
        log = Path(scratch) / "proxy.log"
        with log.open("w") as stream:
            proxy = subprocess.Popen(["telar-proxy", "-all"], stdout=stream, stderr=stream)
            table = f"telar_proxy_{proxy.pid}"
            try:
                wait_ready(proxy, log)
                for destination in destinations:
                    exercise_forwarding(destination, source)
                    assert_tcp_handler(log, destination)
                    assert f"source={TUN_ADDRESS} destination={destination}" in log.read_text()

                # An explicitly bound physical interface intentionally bypasses capture.
                for destination in destinations:
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                        client.settimeout(TEST_TIMEOUT)
                        client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode() + b"\0")
                        client.connect((destination, UDP_PORT))
                        assert client.getsockname()[0] == source
                        client.send(b"bypass-ok")
                        assert json.loads(client.recv(4096)) == {"peer": source, "payload": "bypass-ok"}
                    assert f"source={source} destination={destination}" not in log.read_text()
                print("-all: interface-bound traffic bypassed the TUN in both IPv4 halves", flush=True)

                assert get_route(gateway)["dev"] == interface
                assert command("nft", "list", "table", "ip", SENTINEL_TABLE).stdout == sentinel
                proxy.terminate()
                assert proxy.wait(timeout=TEST_TIMEOUT) == 0, log.read_text()
                assert command("ip", "-j", "-4", "route", "show", "default").stdout == default_route
                for prefix in ("0.0.0.0/1", "128.0.0.0/1"):
                    assert json.loads(command("ip", "-j", "-4", "route", "show", "exact", prefix).stdout) == []
                for destination in destinations:
                    check_cleanup(destination, outbound, sentinel, table)
                    assert http_request(destination)["peer"] == source
                print("-all: capture routes and NAT removed; default and connected routes preserved", flush=True)
            finally:
                if proxy.poll() is None:
                    proxy.terminate()
                    try:
                        proxy.wait(timeout=TEST_TIMEOUT)
                    except subprocess.TimeoutExpired:
                        proxy.kill()
                        proxy.wait()
                print(log.read_text(), flush=True)

            # Fail after the lower-half route has been installed to exercise
            # rollback without deleting an existing route for the upper half.
            upper_half = "128.0.0.0/1"
            command("ip", "-4", "route", "add", upper_half, "via", gateway, "dev", interface,
                    "src", source, "proto", "static")
            previous = command("ip", "-j", "-4", "route", "show", "exact", upper_half).stdout
            proxy = subprocess.Popen(["telar-proxy", "-all"], stdout=stream, stderr=stream)
            try:
                assert proxy.wait(timeout=TEST_TIMEOUT) == 1, log.read_text()
                assert "File exists" in log.read_text(), log.read_text()
                assert json.loads(command("ip", "-j", "-4", "route", "show", "exact", "0.0.0.0/1").stdout) == []
                assert command("ip", "-j", "-4", "route", "show", "exact", upper_half).stdout == previous
                assert command("ip", "-j", "-4", "route", "show", "default").stdout == default_route
                for destination in destinations:
                    check_cleanup(destination, outbound, sentinel, f"telar_proxy_{proxy.pid}")
                print("-all rollback: lower-half route removed; existing upper-half route preserved", flush=True)
            finally:
                if proxy.poll() is None:
                    proxy.terminate()
                    proxy.wait(timeout=TEST_TIMEOUT)
                command("ip", "-4", "route", "del", upper_half, "dev", interface)
                print(log.read_text(), flush=True)



TUN_ADDRESS6 = "fd7a:115c:a1e0:7465::1"


def get_route6(destination):
    return json.loads(command("ip", "-j", "-6", "route", "get", destination).stdout)[0]


def exercise_forwarding6(destination, source, interface=None):
    if interface is None:
        route = get_route6(destination)
        assert route["dev"] == TUN_INTERFACE, route
        assert route["prefsrc"] == TUN_ADDRESS6, route
        ping = command("ping", "-6", "-c", "3", "-W", "2", destination)
        assert "0% packet loss" in ping.stdout, ping.stdout

    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as client:
        client.settimeout(TEST_TIMEOUT)
        if interface:
            client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, interface.encode() + b"\0")
        client.connect((destination, UDP_PORT))
        assert client.getsockname()[0] == (source if interface else TUN_ADDRESS6)
        client.send(b"ipv6-ok")
        reply = json.loads(client.recv(4096))
        assert reply == {"peer": source, "payload": "ipv6-ok"}, reply

    if interface is None:
        # Force IPv6 fragmentation at the TUN MTU, including the return path.
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as fragmented:
            fragmented.settimeout(TEST_TIMEOUT)
            fragmented.connect((destination, UDP_PORT))
            payload = "fragment-ok-" * 300
            fragmented.send(payload.encode())
            assert json.loads(fragmented.recv(8192)) == {"peer": source, "payload": payload}
        assert http_request(destination) == {"peer": source, "payload": "tcp-ok"}
        exercise_tcp_stream(destination, source)
        print(f"{destination}: IPv6 ICMP 3/3 and UDP with NAT66; TCP through the socket relay", flush=True)


def exercise_ipv6(gateway4, gateway6, destinations):
    outbound = get_route6(gateway6)
    interface = outbound["dev"]
    source = outbound["prefsrc"]
    command("ip", "-6", "route", "add", "default", "via", gateway6, "dev", interface)
    default6 = command("ip", "-j", "-6", "route", "show", "default").stdout
    default4 = command("ip", "-j", "-4", "route", "show", "default").stdout
    sysctl6 = command("sysctl", "-n", "net.ipv6.conf.all.forwarding").stdout
    sentinel = command("nft", "list", "table", "ip", SENTINEL_TABLE).stdout

    with tempfile.TemporaryDirectory(prefix="telar-proxy-ipv6-") as scratch:
        log = Path(scratch) / "proxy.log"
        for args in (["-route", destinations[0]], ["-all"]):
            with log.open("w") as stream:
                proxy = subprocess.Popen(["telar-proxy", *args], stdout=stream, stderr=stream)
                table = f"telar_proxy_{proxy.pid}"
                targets = destinations[:1] if args[0] == "-route" else destinations
                try:
                    wait_ready(proxy, log)
                    for destination in targets:
                        exercise_forwarding6(destination, source)
                        assert_tcp_handler(log, destination)
                        exercise_forwarding6(destination, source, interface)
                    if args[0] == "-all":
                        assert "IPv4 capture active:" in log.read_text()
                        assert "IPv6 capture active:" in log.read_text()
                        exercise_forwarding("100.64.1.10", get_route(gateway4)["prefsrc"])
                        exercise_ipv6_extensions(targets[0], TUN_ADDRESS6, source)
                        assert f"Relaying TCP [{TUN_ADDRESS6}]:45874" in log.read_text()
                        assert f"Relaying TCP [{TUN_ADDRESS6}]:45875" in log.read_text()
                    assert get_route6(gateway6)["dev"] == interface
                    proxy.send_signal(signal.SIGINT)
                    assert proxy.wait(timeout=TEST_TIMEOUT) == 0, log.read_text()
                    assert command("nft", "list", "table", "ip6", table, check=False).returncode != 0
                    assert command("nft", "list", "table", "ip", table, check=False).returncode != 0
                    assert command("ip", "-j", "-6", "route", "show", "default").stdout == default6
                    assert command("ip", "-j", "-4", "route", "show", "default").stdout == default4
                    assert command("sysctl", "-n", "net.ipv6.conf.all.forwarding").stdout == sysctl6
                    assert command("nft", "list", "table", "ip", SENTINEL_TABLE).stdout == sentinel
                    assert command("ip", "link", "show", TUN_INTERFACE, check=False).returncode != 0
                    assert not command("conntrack", "-L", "-f", "ipv6", "-s", TUN_ADDRESS6).stdout.strip()
                    for destination in targets:
                        assert get_route6(destination)["dev"] == interface
                        assert http_request(destination)["peer"] == source
                    print(f"{args[0]}: IPv6 bypass and cleanup passed; IPv4, default routes and forwarding sysctl preserved", flush=True)
                finally:
                    if proxy.poll() is None:
                        proxy.terminate()
                        try:
                            proxy.wait(timeout=TEST_TIMEOUT)
                        except subprocess.TimeoutExpired:
                            proxy.kill()
                            proxy.wait()
                    print(log.read_text(), flush=True)

        # A disconnected piped logger must not kill the owner of network state.
        proxy = subprocess.Popen(["telar-proxy", "-all"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            while "Capture ready" not in proxy.stdout.readline():
                assert proxy.poll() is None
            proxy.stdout.close()
            exercise_forwarding6(destinations[0], source)
            assert proxy.poll() is None, "closed log pipe terminated the proxy"
            proxy.terminate()
            assert proxy.wait(timeout=TEST_TIMEOUT) == 0
            for family in ("ip", "ip6"):
                assert command("nft", "list", "table", family, f"telar_proxy_{proxy.pid}", check=False).returncode != 0
            assert command("ip", "link", "show", TUN_INTERFACE, check=False).returncode != 0
            print("Closed log pipe: forwarding continued and both families cleaned on shutdown", flush=True)
        finally:
            if proxy.poll() is None:
                proxy.terminate()
                proxy.wait(timeout=TEST_TIMEOUT)

        # IPv6 failure must also unwind a previously activated IPv4 family.
        command("ip", "-6", "route", "add", "8000::/1", "via", gateway6, "dev", interface)
        previous = command("ip", "-j", "-6", "route", "show", "exact", "8000::/1").stdout
        with log.open("w") as stream:
            proxy = subprocess.Popen(["telar-proxy", "-all"], stdout=stream, stderr=stream)
            try:
                assert proxy.wait(timeout=TEST_TIMEOUT) == 1, log.read_text()
                assert "File exists" in log.read_text(), log.read_text()
                assert command("ip", "-j", "-6", "route", "show", "exact", "8000::/1").stdout == previous
                for family, prefixes in (("-4", ("0.0.0.0/1", "128.0.0.0/1")), ("-6", ("::/1",))):
                    for prefix in prefixes:
                        assert json.loads(command("ip", "-j", family, "route", "show", "exact", prefix).stdout) == []
                for family in ("ip", "ip6"):
                    assert command("nft", "list", "table", family, f"telar_proxy_{proxy.pid}", check=False).returncode != 0
                assert command("ip", "link", "show", TUN_INTERFACE, check=False).returncode != 0
                print("IPv6 rollback: both families cleaned; pre-existing IPv6 route preserved", flush=True)
            finally:
                if proxy.poll() is None:
                    proxy.terminate()
                    proxy.wait(timeout=TEST_TIMEOUT)
                command("ip", "-6", "route", "del", "8000::/1", "dev", interface)
                print(log.read_text(), flush=True)


    # IPv6-only networks must not require an IPv4 default route.
    command("ip", "-4", "route", "del", "default")
    try:
        with tempfile.TemporaryDirectory(prefix="telar-proxy-ipv6-only-") as scratch:
            log = Path(scratch) / "proxy.log"
            with log.open("w") as stream:
                proxy = subprocess.Popen(["telar-proxy", "-all"], stdout=stream, stderr=stream)
                try:
                    wait_ready(proxy, log)
                    assert "IPv6 capture active:" in log.read_text()
                    assert "IPv4 capture active:" not in log.read_text()
                    exercise_forwarding6(destinations[0], source)
                    proxy.terminate()
                    assert proxy.wait(timeout=TEST_TIMEOUT) == 0, log.read_text()
                    assert command("ip", "link", "show", TUN_INTERFACE, check=False).returncode != 0
                    print("IPv6-only network: -all captured IPv6 without an IPv4 default route", flush=True)
                finally:
                    if proxy.poll() is None:
                        proxy.terminate()
                        proxy.wait(timeout=TEST_TIMEOUT)
                    print(log.read_text(), flush=True)
    finally:
        command("ip", "-4", "route", "add", "default", "via", gateway4, "dev", interface)

exercise(sys.argv[1])
exercise_all(sys.argv[1], sys.argv[3:5])
exercise_ipv6(sys.argv[1], sys.argv[2], sys.argv[5:])
exercise_tls([sys.argv[4], sys.argv[5]], [get_route(sys.argv[1])["prefsrc"], get_route6(sys.argv[2])["prefsrc"]])
