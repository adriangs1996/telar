import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess


protocol = r'''
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime T: type) !T {
    var bytes: [@sizeOf(T)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) return error.TruncatedInput;
        byte.* = @intCast(value);
    }
    return @bitCast(bytes);
}
fn write(value: anytype) !void {
    for (std.mem.asBytes(&value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn readText(storage: []u8) ![]const u8 {
    const size = try read(u32);
    if (size > storage.len) return error.TextTooLong;
    for (storage[0..size]) |*byte| byte.* = try read(u8);
    return storage[0..size];
}
fn writeText(text: []const u8) !void {
    try write(@as(u32, @intCast(text.len)));
    for (text) |byte| try write(byte);
}
pub fn main() !void {
    while (getchar() >= 0) {
        const valid_pane = try read(u8) != 0;
        const rows = try read(u16);
        var input_storage: [262144]u8 = undefined;
        var command_storage: [262144]u8 = undefined;
        const input = try readText(&input_storage);
        const command = try readText(&command_storage);
        var screen: PeekScreen = .{};
        screen.show(.{ .pane_id = 9, .pane_generation = 3 });
        screen.reading = true;
        const dropped = screen.store(if (valid_pane) 9 else 10, input);
        try write(if (dropped) |value| @as(u32, @intCast(value)) else std.math.maxInt(u32));
        try write(screen.revision);
        try write(@as(u8, @intFromBool(screen.reading)));
        try writeText(screen.slice());
        var lines = lastLines(screen.slice(), rows);
        var visible: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer visible.deinit();
        var first = true;
        while (lines.next()) |line| {
            if (!first) try visible.writer.writeByte('\n');
            try visible.writer.writeAll(line);
            first = false;
        }
        try writeText(visible.written());
        try write(@as(u8, @intFromEnum(Command.of(command))));
        try writeText(std.mem.trim(u8, command, " \t"));
    }
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixtures():
    cases = []
    commands = [b'', b' ', b'\t/open ', b'/stop', b' /diff\t', b'/Stop', b'/stop now', b'\n/stop', b'Please continue', 'Continúa 🌍'.encode(), b'\0']
    for size in [0, 1, 2, 15, 255, 512, 16380, 16383, 16384, 16385, 16386, 16387, 16388, 65536, 262144]:
        for symbol in [b'x', b'\xc2\xa2', '🌍'.encode(), b'\x80', b'\xff']:
            text = (symbol * (size // len(symbol) + 1))[:size]
            for rows in [0, 1, 2, 16, 65535]:
                cases.append(dict(valid=True, rows=rows, text=text, command=commands[len(cases) % len(commands)]))
    for rows in range(26):
        for suffix in [b'', b'\n', b'\r\n \t', b'\n\n']:
            text = b'\n'.join(str(index).encode() for index in range(40)) + suffix
            cases.append(dict(valid=True, rows=rows, text=text, command=commands[len(cases) % len(commands)]))
    randomizer = random.Random(0x5045454B)
    for index in range(2048):
        alphabet = [b'\n', b' ', b'\t', b'\r', b'content', 'é'.encode(), '🌍'.encode(), b'\x80', b'\xff']
        text = b''.join(randomizer.choices(alphabet, k=randomizer.randrange(1024)))
        if index % 2:
            text *= 20
        cases.append(dict(valid=index % 13 != 0, rows=randomizer.randrange(26), text=text, command=randomizer.choice(commands)))
    return cases


def main():
    parser = argparse.ArgumentParser(description='Compare peek retention, visible tails and slash commands with original Zig bodies')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    (output / 'state').mkdir(parents=True, exist_ok=False)
    (output / 'agents').mkdir()
    originals = ['src/model/state/PeekScreen.zig', 'src/model/agents/AgentKey.zig', 'src/gui/widgets/overlays/PeekModal.zig', 'src/client/agents/agent_peek.zig']
    for name, target in zip(originals[:2], ['state/PeekScreen.zig', 'agents/AgentKey.zig']):
        shutil.copy2(repository / name, output / target)
    modal = (repository / originals[2]).read_text()
    last_lines = modal[modal.index('fn lastLines('):]
    command_source = (repository / originals[3]).read_text()
    command = re.search(r'^pub const Command = enum \{.*?^\};', command_source, re.S | re.M).group()
    for name in originals[2:]:
        shutil.copy2(repository / name, output / Path(name).name)
    (output / 'core.zig').write_text('pub const PaneId = u64;\npub const Limit = struct { pub fn declare(comptime name: []const u8, comptime noun: []const u8, comptime value: usize) void { _ = name; _ = noun; _ = value; } };\n')
    (output / 'probe.zig').write_text('const std = @import("std");\nconst PeekScreen = @import("state/PeekScreen.zig");\n' + command + '\n' + last_lines + '\n' + protocol)
    build = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', '-Mroot=' + str(output / 'probe.zig'), '-Mtelar-core=' + str(output / 'core.zig'), '-femit-bin=' + str(output / 'original-peek')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(build, stdout=log, stderr=subprocess.STDOUT, check=True)
    cases = fixtures()
    requests = b''.join(b'\0' + struct.pack('<BH', case['valid'], case['rows']) + struct.pack('<I', len(case['text'])) + case['text'] + struct.pack('<I', len(case['command'])) + case['command'] for case in cases)
    (output / 'requests.bin').write_bytes(requests)
    results = {}
    for kind, binary in [('original', output / 'original-peek'), ('cpp', options.build_dir.resolve() / 'gui-agent-peek-probe')]:
        result = subprocess.run([str(binary)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        results[kind] = result.stdout
    sources = [*originals, 'services/gui-cpp/peek/command.hpp', 'services/gui-cpp/peek/screen.hpp', 'services/gui-cpp/peek/limits.hpp', 'services/gui-cpp/peek/target.hpp', 'services/gui-cpp/tools/agent_peek_probe.cpp', str(Path(__file__).relative_to(repository))]
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), cases=len(cases), input_bytes=len(requests), input_sha256=sha(requests), bytes={kind:len(data) for kind,data in results.items()}, output_sha256={kind:sha(data) for kind,data in results.items()}, equal=results['original'] == results['cpp'], source_sha256={name:sha((repository/name).read_bytes()) for name in sources}, command=build, scope='Unchanged PeekScreen/AgentKey and exact Command/lastLines bodies. A minimal core facade supplies pane identity and unused limit declaration. Read correlation, session retirement, native geometry/labels and rendering are qualified separately.')
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record))
    assert record['equal']


if __name__ == '__main__':
    main()
