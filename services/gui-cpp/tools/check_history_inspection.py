import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_history_card import pack_text, protocol
from check_notification_center import run
from check_text_fit import unicode_facade


facades = r'''
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const max_tab_label_bytes = 128;
pub fn raw(value: u64) u64 { return value; }
pub const Entry = struct {
    id: u64, pane_id: u64, started_at_ms: i64, duration_ns: i64,
    status: enum { completed, interrupted, running }, exit_code: ?i32,
    author: enum { human, agent }, origin: enum { pane, hook, plugin },
    command: []const u8, cwd: []const u8, provider: []const u8, provider_len: usize,
    pub fn commandSlice(self: *const @This()) []const u8 { return self.command; }
    pub fn cwdSlice(self: *const @This()) []const u8 { return self.cwd; }
    pub fn providerSlice(self: *const @This()) []const u8 { return self.provider; }
};
pub const HistoryPaletteState = struct {
    items: [1]Entry, command: []const u8, now_ms: i64, utc_offset_min: i16,
    output: []const u8, output_len: u32, output_truncated: bool,
    output_phase: enum { idle, loading, ready, failed },
    pub fn slice(self: *const @This()) []const Entry { return &self.items; }
    pub fn commandAt(self: *const @This(), _: u16) ?[]const u8 { return self.command; }
    pub fn outputSlice(self: *const @This()) []const u8 { return self.output; }
    __OUTPUT_HINT__
};
pub const Pane = struct { location: struct { tab_id: u64 = 1 } = .{} };
pub const Panes = struct {
    open: bool, pane: Pane = .{},
    pub fn findConst(self: *const @This(), _: u64) ?*const Pane { return if (self.open) &self.pane else null; }
};
pub const Tabs = struct { pub fn find(_: @This(), _: u64) ?usize { return 0; } };
pub const Model = struct { panes: Panes, tabs: Tabs = .{}, tab: []const u8 };
pub const Projection = struct { history: *const HistoryPaletteState, model: *const Model };
pub const tab_label = struct { pub fn text(model: *const Model, _: usize) []const u8 { return model.tab; } };
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const f = @import("facades.zig");
const Details = @import("HistoryDetails.zig");
pub fn main() !void {
    while (true) {
        _ = io.read(u8) catch return;
        const id = try io.read(u64);
        const pane = try io.read(u64);
        const started = try io.read(i64);
        const duration = try io.read(i64);
        const now = try io.read(i64);
        const offset = try io.read(i16);
        const status = try io.read(u8);
        const has_exit = try io.read(u8) != 0;
        const exit = try io.read(i32);
        const author = try io.read(u8);
        const origin = try io.read(u8);
        const open = try io.read(u8) != 0;
        const phase = try io.read(u8);
        const truncated = try io.read(u8) != 0;
        const columns = try io.read(u16);
        const command = try io.readText();
        const directory = try io.readText();
        const provider = try io.readText();
        const tab = try io.readText();
        const output = try io.readText();
        const history: f.HistoryPaletteState = .{
            .items = .{.{ .id = id, .pane_id = pane, .started_at_ms = started, .duration_ns = duration,
                .status = @enumFromInt(status), .exit_code = if (has_exit) exit else null,
                .author = @enumFromInt(author), .origin = @enumFromInt(origin),
                .command = command, .cwd = directory, .provider = provider, .provider_len = provider.len }},
            .command = command, .now_ms = now, .utc_offset_min = offset,
            .output = output, .output_len = @intCast(output.len), .output_truncated = truncated,
            .output_phase = @enumFromInt(phase),
        };
        const model: f.Model = .{ .panes = .{ .open = open }, .tab = tab };
        const projection: f.Projection = .{ .history = &history, .model = &model };
        const details = Details.init(&projection, 0);
        var lines = details.lines(columns);
        try io.write(lines.count());
        while (lines.next()) |line| {
            try io.write(@as(u8, @intFromEnum(line.kind)));
            try io.write(@as(u8, @intFromEnum(line.tone)));
            try io.write(@as(u8, @intFromBool(line.mono)));
            try io.writeText(line.label);
            try io.writeText(line.text);
        }
    }
}
'''


def prepare(repository, build, output):
    from check_notification_center import function_source

    original = repository / 'src/gui/widgets/overlays'
    details = (original / 'HistoryDetails.zig').read_text()
    for name in ['model', 'telar-core', 'telar-client']:
        details = details.replace(f'@import("{name}")', '@import("facades.zig")')
    (output / 'HistoryDetails.zig').write_text(details)
    for name in ['HistoryLine.zig', 'WrappedLines.zig', 'history_labels.zig']:
        shutil.copy2(original / name, output / name)
    source = (repository / 'src/model/state/HistoryPaletteState.zig').read_text()
    hint = function_source(source, 'outputHint').replace('*const State', '*const @This()')
    (output / 'facades.zig').write_text(facades.replace('__OUTPUT_HINT__', hint))
    (output / 'protocol.zig').write_text(protocol)
    (output / 'probe.zig').write_text(reference)
    for name in ['GraphemeIterator.zig', 'Cluster.zig', 'text.zig']:
        shutil.copy2(repository / 'lib/cellgrid' / name, output / name)
    (output / 'cellgrid.zig').write_text('pub const GraphemeIterator = @import("GraphemeIterator.zig");\npub const text = @import("text.zig");\n')
    (output / 'unicode.zig').write_text(unicode_facade)
    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    library = next(line.split('=', 1)[1] for line in cache if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH='))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', library,
               '--dep', 'cellgrid', f'-Mroot={output / "probe.zig"}', '--dep', 'unicode',
               f'-Mcellgrid={output / "cellgrid.zig"}', f'-Municode={output / "unicode.zig"}', f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def record(command=b'echo one two three', output=b'', columns=80, status=0, exit_code=None,
           author=0, origin=0, pane_open=False, phase=2, truncated=False,
           started=1_700_000_000_000, now=1_700_000_100_000, offset=0, duration=0,
           identifier=1, pane=2, provider=b'', tab=b'shell', directory=b'/project'):
    header = struct.pack('<BQQqqqhBBiBBBBBH', 0, identifier, pane, started, duration, now, offset,
                         status, exit_code is not None, exit_code or 0, author, origin, pane_open, phase, truncated, columns)
    return header + b''.join(pack_text(value) for value in [command, directory, provider, tab, output])


def fixtures():
    for status, code, author, origin, opened, phase in itertools.product(range(3), [None, 0, -1, 127, -(2**31)], range(2), range(3), [False, True], range(4)):
        yield record(status=status, exit_code=code, author=author, origin=origin, pane_open=opened, phase=phase)
    for count in [0, 1, 1023, 1024, 1025, 65535]:
        for phase, truncated in itertools.product(range(4), [False, True]):
            yield record(output=b'x' * count, columns=65535, phase=phase, truncated=truncated)
    for started, duration, offset in itertools.product([-1, 0, 1, 253_402_300_799_999, 253_402_300_800_000], [-1, 0, 999_000_000, 60_000_000_000], [-840, 0, 840]):
        yield record(started=started, duration=duration, offset=offset, identifier=2**64-1, pane=2**64-1, provider=b'x'*64, tab=b't'*128, pane_open=True, author=1, origin=2)
    texts = [b'', b'one two three', b'one\r\n\nlast\n', '中 👩🏽‍💻 á'.encode(), b'a\xff\xe2\x82b', b' ' * 100]
    for command, output, columns in itertools.product(texts, texts, [0, 1, 2, 7, 80]):
        yield record(command=command, output=output, columns=columns)
    generator = random.Random(0x1A5E7)
    alphabet = ['a', ' ', '\t', '\r', '\n', '中', '🧵', 'á']
    for _ in range(2000):
        command = ''.join(generator.choice(alphabet) for _ in range(generator.randrange(120))).encode()
        output = ''.join(generator.choice(alphabet) for _ in range(generator.randrange(120))).encode()
        yield record(command=command, output=output, columns=generator.choice([0, 1, 2, 7, 80]), status=generator.randrange(3), exit_code=generator.choice([None, -1, 0, 1]), author=generator.randrange(2), origin=generator.randrange(3), pane_open=bool(generator.randrange(2)))


def main():
    parser = argparse.ArgumentParser(description='Compare inspector facts and complete line sequences with the original Zig implementation')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, options.build_dir.resolve(), output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-history-inspection-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (a, b) in enumerate(zip(actual, expected)) if a != b), min(len(actual), len(expected)))
        raise RuntimeError(f'Inspector differs at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_inspection_probe.cpp')]
    sources += [repository / path for path in ['src/gui/widgets/overlays/HistoryDetails.zig', 'src/gui/widgets/overlays/HistoryLine.zig', 'src/model/state/HistoryPaletteState.zig', 'services/gui-cpp/presentation/history_inspection.hpp', 'services/gui-cpp/text/wrapped_lines.hpp']]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(), reference_command=command, source_sha256={str(path.relative_to(repository)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, scope='Original inspector facts, output headings and complete borrowed line sequence. Geometry, rasterization, interaction, physical IME and performance remain outside this comparison.')
    (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Matched', len(cases), 'original inspector records')


if __name__ == '__main__':
    main()
