import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import struct
import subprocess

from check_peek_labels import protocol
from check_runtime_link import function


def sha(data):
    return hashlib.sha256(data).hexdigest()


facade = r'''
const std = @import("std");
const wire = @import("handshake.zig");
const RuntimeLink = @import("RuntimeLink.zig");
const core = struct {
    const SchemaId = wire.SchemaId;
    const schema_id = wire.schema_id;
    const max_message_size = wire.max_message_size;
    const ServerResponse = wire.ServerResponse;
    const encodeClientHello = wire.encodeClientHello;
    const decodeServerResponse = wire.decodeServerResponse;
    const ClientList = struct { CAPACITY };
};
const localsocket = struct { const SocketChannel = Channel; };
const Channel = struct {
    payload: []const u8,
    sends: *u8,
    closes: *u8,
    fn send(self: *Channel, _: std.Io, bytes: []const u8) !void {
        var expected: [wire.client_hello_size]u8 = undefined;
        const encoded = try wire.encodeClientHello(&expected, .{});
        if (!std.mem.eql(u8, bytes, encoded)) { return error.WrongClientHello; }
        self.sends.* += 1;
    }
    fn receive(self: *Channel, _: std.Io, storage: []u8) ![]u8 {
        if (self.payload.len > storage.len) { return error.BufferTooSmall; }
        @memcpy(storage[0..self.payload.len], self.payload);
        return storage[0..self.payload.len];
    }
    fn deinit(self: *Channel, _: std.Io) void { self.closes.* += 1; }
};
'''


main_body = r'''
pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    while (getchar() >= 0) {
        var storage: [65536]u8 = undefined;
        const payload = try readText(&storage);
        var report: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&report);
        var sends: u8 = 0;
        var closes: u8 = 0;
        const connection: Channel = .{ .payload = payload, .sends = &sends, .closes = &closes };
        const result = negotiate(io, connection, &writer);
        var link: RuntimeLink = .{};
        var accepted: u8 = 0;
        var is_permanent: u8 = 0;
        if (result) |_| {
            accepted = 1;
            if (closes != 0) { return error.AcceptedChannelClosed; }
        } else |err| {
            if (closes != 1) { return error.RefusedChannelNotClosed; }
            link.fail(if (writer.end != 0) report[0..writer.end] else @errorName(err));
            is_permanent = @intFromBool(permanent(err));
        }
        if (sends != 1) { return error.WrongHandshakeSendCount; }
        if (putchar(accepted) < 0 or putchar(is_permanent) < 0) { return error.WriteFailed; }
        try writeText(link.failure() orelse "");
    }
}
'''


def fixtures():
    magic = b'TELARIPC'
    schema = b'886b480d'
    accept = magic + b'\x02' + schema
    reject = magic + b'\x03\x01' + schema
    cases = [accept, reject, magic + b'\x03\x02' + schema, magic + b'\x01' + schema]
    for tag in range(256):
        for length in range(34):
            cases.append((magic + bytes([tag]) + schema + bytes(32))[:length])
    for first in range(256):
        for second in range(256):
            cases.append(magic + b'\x03\x01' + bytes([first, second]) + schema[2:])
    for reason in range(256):
        for expected in [schema, bytes(8), bytes([255]) * 8, 'é中abc'.encode()]:
            assert len(expected) == 8
            cases.append(magic + b'\x03' + bytes([reason]) + expected)
    randomizer = random.Random(0x48414E44)
    for _ in range(4096):
        payload = bytearray(randomizer.choice([accept, reject]))
        for _ in range(randomizer.randrange(1, 5)):
            payload[randomizer.randrange(len(payload))] = randomizer.randrange(256)
        if randomizer.getrandbits(1):
            payload = payload[:randomizer.randrange(len(payload) + 1)]
        cases.append(bytes(payload))
    cases.extend([b'', bytes(65536), accept + bytes(4096)])
    return cases


def main():
    parser = argparse.ArgumentParser(description='Compare runtime handshake refusals, decoder errors and permanent policy against original Zig')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    originals = ['src/core/schema/' + name for name in ['handshake.zig', 'ServerAccept.zig', 'ServerReject.zig', 'ClientHello.zig']]
    originals += ['src/model/connection/RuntimeLink.zig', 'src/core/ClientList.zig', 'src/client/transport/handshake.zig', 'src/client/machines/RuntimeConnector.zig', 'src/client/machines/machine_connection.zig', 'lib/localsocket/transport.zig']
    for name in originals:
        destination = output / (Path(name).name if name not in ['src/client/transport/handshake.zig', 'lib/localsocket/transport.zig'] else str(Path(name).parent.name) + '-' + Path(name).name)
        destination.write_bytes((repository / name).read_bytes())
    transport = (repository / 'src/client/transport/handshake.zig').read_text()
    connector = (repository / 'src/client/machines/RuntimeConnector.zig').read_text()
    policy = (repository / 'src/client/machines/machine_connection.zig').read_text()
    capacity = re.search(r'pub const capacity = .*?;', (repository / 'src/core/ClientList.zig').read_text()).group().replace('pub ', '')
    constant = re.search(r'pub const client_limit_reached = std\.fmt\.comptimePrint\([\s\S]*?\n\);', connector).group()
    original = facade.replace('CAPACITY', capacity) + '\nconst handshake = struct {\n' + function(transport, 'perform') + '\n' + function(transport, 'performSchema') + '\n};\n' + constant + '\n' + function(connector, 'negotiate') + '\n' + function(policy, 'permanent') + '\n' + protocol + main_body
    (output / 'probe.zig').write_text(original)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original-handshake')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = fixtures()
    requests = b''.join(b'\0' + struct.pack('<I', len(case)) + case for case in cases)
    (output / 'requests.bin').write_bytes(requests)
    binary = options.build_dir.resolve() / 'gui-runtime-handshake-probe'
    results = {}
    for kind, executable in [('original', output / 'original-handshake'), ('cpp', binary)]:
        result = subprocess.run([str(executable)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        results[kind] = result.stdout
    def parse(data):
        values, offset = [], 0
        for _ in cases:
            accepted, permanent, length = struct.unpack_from('<BBI', data, offset)
            offset += 6
            values.append([accepted, permanent, data[offset:offset + length].hex()])
            offset += length
        assert offset == len(data)
        return values
    left, right = [parse(results[kind]) for kind in ['original', 'cpp']]
    differences = [dict(index=index, payload=cases[index].hex(), original=first, cpp=second) for index, (first, second) in enumerate(zip(left, right)) if first != second]
    (output / 'differences.json').write_text(json.dumps(differences, indent=2) + '\n')
    sources = originals + ['services/gui-cpp/transport/runtime_handshake.hpp', 'services/gui-cpp/tools/runtime_handshake_probe.cpp', 'services/gui-cpp/tools/check_runtime_handshake.py', 'services/gui-cpp/tools/check_runtime_link.py', 'services/gui-cpp/tools/check_peek_labels.py']
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), command=command, cases=len(cases), different_cases=len(differences), input_sha256=sha(requests), output_sha256={key:sha(value) for key,value in results.items()}, source_sha256={name:sha((repository / name).read_bytes()) for name in sources}, binary_sha256=sha(binary.read_bytes()), sanitizer_environment={key:os.environ.get(key) for key in ['ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS']}, scope='Whole original schema decoder/types and RuntimeLink; unchanged perform/performSchema, RuntimeConnector.negotiate and permanent bodies. Field-only core/channel facade records the sent hello and refused-channel close and implements original bounded payload receive. Stream prefix fragmentation, real socket lifecycle, worker/SSH policy and GUI presentation are separate checks.')
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    assert not differences


if __name__ == '__main__':
    main()
