"""An authenticated, temporary TCP echo origin on a user-controlled SSH host."""

import ipaddress
import enum
import os
import selectors
import shlex
import socket
import subprocess
import types
import sys


class DarwinSocketOption(enum.IntEnum):
    # Python 3.9 does not expose these options from the macOS SDK headers.
    bound_ipv4 = 25
    bound_ipv6 = 125


def connect_origin(destination, interface=None):
    if interface is None:
        return socket.create_connection(destination, timeout=5)
    if sys.platform != "darwin":
        raise ValueError("Interface-bound acceptance currently requires macOS")
    index = socket.if_nametoindex(interface)
    ipv6 = ipaddress.ip_address(destination[0]).version == 6
    level = socket.IPPROTO_IPV6 if ipv6 else socket.IPPROTO_IP
    option = DarwinSocketOption.bound_ipv6 if ipv6 else DarwinSocketOption.bound_ipv4
    client = socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET, socket.SOCK_STREAM)
    try:
        client.settimeout(5)
        client.setsockopt(level, option, index)
        if client.getsockopt(level, option) != index:
            raise RuntimeError("The socket did not bind to the selected interface")
        client.connect(destination)
        if client.getsockopt(level, option) != index:
            raise RuntimeError("The connected socket lost its interface binding")
        return client
    except BaseException:
        client.close()
        raise


SERVER = r'''
import os, socket, struct, sys, threading
cookie = bytes.fromhex(sys.argv[1])
endpoint = len(sys.argv) > 2 and sys.argv[2] == "endpoint"
server = socket.socket()
server.bind(("0.0.0.0", 0))
server.listen(16)
def stop():
    sys.stdin.buffer.read()
    os._exit(0)
threading.Thread(target=stop, daemon=True).start()
def echo(client, peer):
    with client:
        client.settimeout(10)
        try:
            received = bytearray()
            while len(received) < len(cookie):
                part = client.recv(len(cookie) - len(received))
                if not part: return
                received.extend(part)
            if received != cookie: return
            client.sendall(struct.pack("!4sH", socket.inet_aton(peer[0]), peer[1]) if endpoint else struct.pack("!H", peer[1]))
            while data := client.recv(65536): client.sendall(data)
        except OSError: pass
print(server.getsockname()[1], flush=True)
while True:
    client, peer = server.accept()
    threading.Thread(target=echo, args=(client, peer), daemon=True).start()
'''


class EchoProcess:
    def __init__(self, arguments, address, cookie):
        self.cookie = cookie
        self.process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                if not selector.select(8):
                    raise RuntimeError("SSH origin did not announce its port")
                line = self.process.stdout.readline()
                if not line:
                    raise RuntimeError("SSH origin failed: " + self.process.stderr.read())
                self.port = int(line)
            self.socket = types.SimpleNamespace(getsockname=lambda: (address, self.port))
        except Exception:
            self.close()
            raise

    def authenticate(self, client):
        client.sendall(self.cookie)

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.process.stdout.close()
        self.process.stderr.close()


def controlled_address(host, address=None):
    if not host or host.startswith("-") or any(char.isspace() for char in host):
        raise ValueError("Invalid SSH origin host")
    selected = str(ipaddress.ip_address(address or socket.gethostbyname(host.rsplit("@", 1)[-1])))
    if ipaddress.ip_address(selected).version != 4:
        raise ValueError("The temporary SSH echo origin currently requires IPv4")
    return selected


class RemoteOrigin(EchoProcess):
    def __init__(self, host, address=None):
        selected = controlled_address(host, address)
        cookie = os.urandom(32)
        arguments = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5", host,
                     "python3 -u -c " + shlex.quote(SERVER) + " " + cookie.hex()]
        super().__init__(arguments, selected, cookie)


class LocalOrigin(EchoProcess):
    def __init__(self, address):
        selected = str(ipaddress.IPv4Address(address))
        cookie = os.urandom(32)
        super().__init__([sys.executable, "-u", "-c", SERVER, cookie.hex(), "endpoint"], selected, cookie)
