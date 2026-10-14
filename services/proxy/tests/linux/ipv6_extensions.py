from contextlib import closing
import json
import secrets
import socket
import struct
import subprocess
import time

IPV6_HEADER_INCLUDED = 36
HOP_OPTIONS = 0
DESTINATION_OPTIONS = 60
FRAGMENT = 44
TCP_PORT = 8080
UDP_PORT = 5353
TCP_SYN = 2
TCP_ACK = 16
TCP_PUSH = 8
TCP_FIN = 1
TEST_TIMEOUT = 10
FRAGMENT_CHUNK = 1200


def transport_checksum(source, destination, protocol, payload):
    pseudo = socket.inet_pton(socket.AF_INET6, source) + socket.inet_pton(socket.AF_INET6, destination)
    data = pseudo + struct.pack("!I3xB", len(payload), protocol) + payload
    if len(data) % 2:
        data += b"\0"
    checksum = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while checksum >> 16:
        checksum = (checksum & 65535) + (checksum >> 16)
    return (~checksum) & 65535


def ipv6_packet(source, destination, protocol, payload):
    return struct.pack("!IHBB16s16s", 6 << 28, len(payload), protocol, 64,
                       socket.inet_pton(socket.AF_INET6, source), socket.inet_pton(socket.AF_INET6, destination)) + payload


def extension_fragments(source, destination, protocol, transport, atomic=False):
    # Padding-only options before and after the Fragment header.
    hop = bytes([FRAGMENT, 0, 1, 4, 0, 0, 0, 0])
    payload = bytes([protocol, 0, 1, 4, 0, 0, 0, 0]) + transport
    identifier = secrets.randbits(32)
    chunks = [payload] if atomic else [payload[:32]] + [payload[index:index + FRAGMENT_CHUNK] for index in range(32, len(payload), FRAGMENT_CHUNK)]
    frames = []
    offset = 0
    for index, chunk in enumerate(chunks):
        more = index < len(chunks) - 1
        fragment = struct.pack("!BBHI", DESTINATION_OPTIONS, 0, offset | int(more), identifier)
        frames.append(ipv6_packet(source, destination, HOP_OPTIONS, hop + fragment + chunk))
        offset += len(chunk)
    return frames


def raw_sender(source):
    sender = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_RAW)
    sender.setsockopt(socket.IPPROTO_IPV6, IPV6_HEADER_INCLUDED, 1)
    sender.bind((source, 0))
    return sender


def send_frames(sender, destination, frames, reverse=False):
    for frame in reversed(frames) if reverse else frames:
        sender.sendto(frame, (destination, 0))


def udp_extensions(destination, source, outbound, reverse):
    payload = b"options-after-fragment-" * 170
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as application, closing(raw_sender(source)) as sender:
        application.settimeout(TEST_TIMEOUT)
        application.bind((source, 0))
        application.connect((destination, UDP_PORT))
        header = struct.pack("!HHHH", application.getsockname()[1], UDP_PORT, 8 + len(payload), 0)
        checksum = transport_checksum(source, destination, socket.IPPROTO_UDP, header + payload)
        transport = header[:6] + struct.pack("!H", checksum or 65535) + payload
        send_frames(sender, destination, extension_fragments(source, destination, socket.IPPROTO_UDP, transport), reverse)
        assert json.loads(application.recv(8192)) == {"peer": outbound, "payload": payload.decode()}


def icmp_extensions(destination, source, reverse):
    payload = b"icmp-options-after-fragment-" * 110
    identifier = secrets.randbits(16)
    header = struct.pack("!BBHHH", 128, 0, 0, identifier, 1)
    checksum = transport_checksum(source, destination, socket.IPPROTO_ICMPV6, header + payload)
    transport = header[:2] + struct.pack("!H", checksum) + header[4:] + payload
    with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as application, closing(raw_sender(source)) as sender:
        application.settimeout(TEST_TIMEOUT)
        application.bind((source, 0))
        send_frames(sender, destination, extension_fragments(source, destination, socket.IPPROTO_ICMPV6, transport), reverse)
        deadline = time.monotonic() + TEST_TIMEOUT
        while time.monotonic() < deadline:
            reply, peer = application.recvfrom(8192)
            if peer[0] == destination and reply[0] == 129 and reply[4:8] == transport[4:8]:
                assert reply[8:] == payload
                return
        raise AssertionError("no fragmented ICMPv6 echo reply")


class TCPProbe:
    def __init__(self, source, destination, port):
        self.source = source
        self.destination = destination
        self.port = port
        self.sequence = 12345
        self.acknowledgement = 0
        self.sender = raw_sender(source)
        self.receiver = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_TCP)
        self.receiver.bind((source, 0))
        self.receiver.settimeout(TEST_TIMEOUT)

    def close(self):
        self.receiver.close()
        self.sender.close()

    def segment(self, flags, payload=b""):
        header = struct.pack("!HHIIBBHHH", self.port, TCP_PORT, self.sequence, self.acknowledgement, 5 << 4, flags, 65535, 0, 0)
        checksum = transport_checksum(self.source, self.destination, socket.IPPROTO_TCP, header + payload)
        return header[:16] + struct.pack("!H", checksum) + header[18:] + payload

    def send(self, flags, payload=b"", fragmented=False, reverse=False):
        transport = self.segment(flags, payload)
        if fragmented:
            frames = extension_fragments(self.source, self.destination, socket.IPPROTO_TCP, transport, atomic=flags == TCP_SYN)
        else:
            frames = [ipv6_packet(self.source, self.destination, socket.IPPROTO_TCP, transport)]
        send_frames(self.sender, self.destination, frames, reverse)

    def receive(self):
        deadline = time.monotonic() + TEST_TIMEOUT
        while time.monotonic() < deadline:
            packet, peer = self.receiver.recvfrom(8192)
            if peer[0] == self.destination and struct.unpack("!HH", packet[:4]) == (TCP_PORT, self.port):
                offset = (packet[12] >> 4) * 4
                return struct.unpack("!I", packet[4:8])[0], packet[13], packet[offset:]
        raise AssertionError("no TCP reply")

    def request(self, reverse):
        self.send(TCP_SYN, fragmented=True)
        sequence, flags, _ = self.receive()
        assert flags & (TCP_SYN | TCP_ACK) == TCP_SYN | TCP_ACK
        self.sequence += 1
        self.acknowledgement = sequence + 1
        self.send(TCP_ACK)
        request = b"GET / HTTP/1.1\r\nHost: proxy.test\r\nConnection: close\r\n\r\n"
        self.send(TCP_ACK | TCP_PUSH, request, fragmented=True, reverse=reverse)
        self.sequence += len(request)
        response = bytearray()
        deadline = time.monotonic() + TEST_TIMEOUT
        while time.monotonic() < deadline:
            sequence, flags, payload = self.receive()
            if sequence == self.acknowledgement:
                response.extend(payload)
                self.acknowledgement += len(payload)
                if flags & TCP_FIN:
                    self.acknowledgement += 1
                    self.send(TCP_ACK | TCP_FIN)
                    return bytes(response)
            self.send(TCP_ACK)
        raise AssertionError("TCP response did not finish")


def exercise_ipv6_extensions(destination, source, outbound):
    table = "telar_test_ipv6_extensions"
    rules = f'''create table ip6 {table}
add chain ip6 {table} output {{ type filter hook output priority filter; policy accept; }}
add rule ip6 {table} output ip6 saddr {source} ip6 daddr {destination} tcp sport {{ 45874, 45875 }} tcp flags & rst == rst drop
'''
    subprocess.run(["nft", "-f", "-"], input=rules, text=True, check=True)
    try:
        for reverse in (False, True):
            udp_extensions(destination, source, outbound, reverse)
            icmp_extensions(destination, source, reverse)
            with closing(TCPProbe(source, destination, 45875 if reverse else 45874)) as probe:
                response = probe.request(reverse)
                head, body = response.split(b"\r\n\r\n", 1)
                assert head.startswith(b"HTTP/1.0 200"), response
                assert json.loads(body) == {"peer": outbound, "payload": "tcp-ok"}
            print(f"IPv6 extensions after Fragment: TCP, UDP and ICMPv6 passed, reversed={reverse}", flush=True)
    finally:
        subprocess.run(["nft", "delete", "table", "ip6", table], check=True)
