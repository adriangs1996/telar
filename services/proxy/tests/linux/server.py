import json
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HTTP_PORT = 8080
HTTPS_PORT = 8443
UDP_PORT = 5353
TCP_STREAM_PORT = 9090
TCP_STREAM_LIMIT = 4 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"peer": self.client_address[0], "payload": "tcp-ok"}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class StreamHandler(socketserver.BaseRequestHandler):
    def handle(self):
        chunks = []
        size = 0
        while chunk := self.request.recv(65536):
            size += len(chunk)
            if size > TCP_STREAM_LIMIT:
                return
            chunks.append(chunk)
        payload = b"".join(chunks)
        metadata = json.dumps({"peer": self.client_address[0], "size": size}).encode()
        self.request.sendall(metadata + b"\n" + payload[::-1])


class StreamServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


class IPv6StreamServer(StreamServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def serve_udp(address):
    with socket.socket(socket.AF_INET6 if ":" in address else socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind((address, UDP_PORT))
        while True:
            data, peer = server.recvfrom(4096)
            reply = json.dumps({"peer": peer[0], "payload": data.decode()}).encode()
            server.sendto(reply, peer)


aliases = sys.argv[1:]
for address in aliases:
    subprocess.run(["ip", "-6" if ":" in address else "-4", "address", "add", address + ("/128" if ":" in address else "/32"), "dev", "lo"], check=True)
addresses6 = json.loads(subprocess.check_output(["ip", "-j", "-6", "address", "show", "dev", "eth0"], text=True))
source6 = next(info["local"] for info in addresses6[0]["addr_info"] if info["scope"] == "global")
for address in [socket.gethostbyname(socket.gethostname()), source6, *aliases]:
    threading.Thread(target=serve_udp, args=(address,), daemon=True).start()
class IPv6HTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


threading.Thread(target=IPv6HTTPServer(("::", HTTP_PORT), Handler).serve_forever, daemon=True).start()
tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls_context.load_cert_chain("/tests/tls-fixtures/server.pem", "/tests/tls-fixtures/server-key.pem")
tls_context.set_alpn_protocols(["http/1.1"])
for server_type, address in ((ThreadingHTTPServer, "0.0.0.0"), (IPv6HTTPServer, "::")):
    secured_server = server_type((address, HTTPS_PORT), Handler)
    secured_server.socket = tls_context.wrap_socket(secured_server.socket, server_side=True)
    threading.Thread(target=secured_server.serve_forever, daemon=True).start()
threading.Thread(target=StreamServer(("0.0.0.0", TCP_STREAM_PORT), StreamHandler).serve_forever, daemon=True).start()
threading.Thread(target=IPv6StreamServer(("::", TCP_STREAM_PORT), StreamHandler).serve_forever, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler).serve_forever()
