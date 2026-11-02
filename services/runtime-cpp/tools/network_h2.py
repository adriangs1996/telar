"""Independent HTTP/2 peers for the native C++/Lua interception acceptance test."""

import gzip
import random
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, PingAckReceived, RequestReceived, ResponseReceived, StreamEnded, StreamReset, TrailersReceived


FAST_BODY = b"client\0" + random.Random(1776).randbytes(512 * 1024)
HELD_BODY = b"held\0" * 1024


def send_bodies(connection, socket, pending):
    for stream, state in list(pending.items()):
        while state[1] < len(state[0]):
            size = min(connection.local_flow_control_window(stream), connection.max_outbound_frame_size, len(state[0]) - state[1])
            if size <= 0: break
            final = state[1] + size == len(state[0])
            connection.send_data(stream, state[0][state[1]:state[1] + size], end_stream=final and not state[2])
            state[1] += size
        if state[1] == len(state[0]):
            if state[2]: connection.send_headers(stream, state[2], end_stream=True)
            elif not state[0]: connection.send_data(stream, b"", end_stream=True)
            del pending[stream]
    output = connection.data_to_send()
    if output: socket.sendall(output)


def serve(socket):
    connection = H2Connection(config=H2Configuration(client_side=False, header_encoding="utf-8"))
    connection.initiate_connection()
    socket.sendall(connection.data_to_send())
    streams, pending, completed = {}, {}, []
    while data := socket.recv(65536):
        for event in connection.receive_data(data):
            if isinstance(event, RequestReceived):
                streams[event.stream_id] = {"headers": dict(event.headers), "body": bytearray()}
            elif isinstance(event, DataReceived):
                streams[event.stream_id]["body"].extend(event.data)
                connection.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, StreamEnded):
                request = streams[event.stream_id]
                path = request["headers"][":path"]
                body = bytes(request["body"])
                if request["headers"].get("content-encoding") == "gzip": body = gzip.decompress(body)
                expected = b"req\0" + (FAST_BODY if path == "/edited/fast" else HELD_BODY) + b"\0end"
                if path == "/release":
                    if body: raise RuntimeError("HTTP/2 release request changed")
                elif path not in ("/edited/fast", "/edited/hold") or body != expected:
                    raise RuntimeError("HTTP/2 request edits differed")
                completed.append(path)
                encoded = gzip.compress(b"origin\0" + body)
                connection.send_headers(event.stream_id, [(":status", "200"), ("content-encoding", "gzip"), ("content-length", str(len(encoded)))])
                pending[event.stream_id] = [encoded, 0, [("x-origin", "fixture")]]
            elif isinstance(event, (StreamReset, ConnectionTerminated)):
                raise RuntimeError(f"Unexpected origin HTTP/2 termination: {event}")
        send_bodies(connection, socket, pending)
    if len(completed) != 3 or completed[0] != "/edited/fast" or set(completed) != {"/edited/fast", "/edited/hold", "/release"} or pending:
        raise RuntimeError(f"HTTP/2 origin exchanges incomplete: {completed}, {list(pending)}")
    return b"verified"


def exchange(socket):
    connection = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
    connection.initiate_connection()
    pending, responses, complete = {}, {}, set()
    for stream, path, body in ((1, "/hold", HELD_BODY), (3, "/fast", FAST_BODY)):
        encoded = gzip.compress(body)
        connection.send_headers(stream, [(":method", "POST"), (":scheme", "http"), (":authority", "fixture.test"), (":path", path), ("content-encoding", "gzip"), ("content-length", str(len(encoded)))])
        pending[stream] = [encoded, 0, []]
    connection.ping(b"tlr-ping")
    send_bodies(connection, socket, pending)
    pong, released, finish = False, False, False
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        data = socket.recv(65536)
        if not data: raise RuntimeError("HTTP/2 connection closed before completion")
        for event in connection.receive_data(data):
            if isinstance(event, ResponseReceived):
                responses[event.stream_id] = {"headers": dict(event.headers), "body": bytearray(), "trailers": {}}
                if event.stream_id == 1 and not released: raise RuntimeError("Held HTTP/2 stream was forwarded early")
            elif isinstance(event, DataReceived):
                responses[event.stream_id]["body"].extend(event.data)
                connection.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, TrailersReceived):
                responses[event.stream_id]["trailers"] = dict(event.headers)
            elif isinstance(event, PingAckReceived):
                pong = True
            elif isinstance(event, StreamEnded):
                response = responses[event.stream_id]
                expected = b"origin\0" if event.stream_id == 5 else b"res\0origin\0req\0" + (FAST_BODY if event.stream_id == 3 else HELD_BODY) + b"\0end\0end"
                if gzip.decompress(bytes(response["body"])) != expected:
                    raise RuntimeError("HTTP/2 edited binary response differed")
                if event.stream_id != 5 and (response["headers"].get(":status") != "201" or response["headers"].get("x-telar-response") != "yes" or response["trailers"].get("x-rewritten") != "done"):
                    raise RuntimeError("HTTP/2 response fields or trailers were lost")
                complete.add(event.stream_id)
            elif isinstance(event, StreamReset):
                if event.stream_id == 7 and finish: return
                raise RuntimeError(f"Unexpected HTTP/2 stream reset: {event}")
            elif isinstance(event, ConnectionTerminated):
                raise RuntimeError(f"Unexpected HTTP/2 GOAWAY: {event}")
        if 3 in complete and pong and not released:
            if 1 in complete: raise RuntimeError("HTTP/2 stream pause was not independent")
            released = True
            connection.send_headers(5, [(":method", "POST"), (":scheme", "http"), (":authority", "fixture.test"), (":path", "/release")], end_stream=True)
        if complete == {1, 3, 5} and not finish:
            finish = True
            connection.send_headers(7, [(":method", "POST"), (":scheme", "http"), (":authority", "fixture.test"), (":path", "/finish")], end_stream=True)
        send_bodies(connection, socket, pending)
    raise RuntimeError("HTTP/2 hook acceptance timed out")
