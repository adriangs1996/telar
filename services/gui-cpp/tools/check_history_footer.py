import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import struct
import subprocess

from check_history_card import pack_text
from check_history_facts import prepare_hint_sources
from check_notification_center import function_source, run


measure = r'''
pub fn measure(self: *@This(), label: Label) !f32 {
    for (self.hint_keys, self.hint_words, 0..) |key, word, index| {
        if (std.mem.eql(u8, label.text, key)) return self.action_widths[index][0];
        if (std.mem.eql(u8, label.text, word)) return self.action_widths[index][1];
    }
    return self.range_width;
}
'''


fill = r'''
pub fn fillAt(_: *@This(), bounds: Rect, color: Color) !void {
    try io.write(@as(u8, 4));
    try io.writeRect(bounds);
    try io.writeText(@tagName(color));
}
'''


modal = r'''
const std = @import("std");
const types = @import("facades.zig");
const Canvas = types.Canvas;
const Rect = types.Rect;
const Label = types.Label;
const key_label = types.key_label;
const HistoryHint = @import("HistoryHint.zig");
const HistoryModal = @This();
const Caption = struct {
    bounds: Rect,
    label: Label,
    pub fn draw(self: @This(), canvas: *Canvas) !void {
        if (self.bounds.width > 0) _ = try canvas.textAt(self.bounds, self.label);
    }
};
projection: *const types.Projection,
layout: struct { footer: Rect },
query: []const u8,
fn queryFilters(self: HistoryModal) struct { query: []const u8 } { return .{ .query = self.query }; }
fn hintAction(_: HistoryModal, _: HintAction) ?types.Target.Action { return null; }
'''


reference = r'''
const io = @import("protocol.zig");
const std = @import("std");
const types = @import("facades.zig");
const Footer = @import("Footer.zig");
fn frame() !void {
    const area = try io.readRect();
    const ratio = try io.read(f32);
    const small = try io.read(u16);
    types.key_label.host_style = if (try io.read(u8) == 0) .mac else .pc;
    const flags = try io.read(u8);
    const offset = try io.read(u32);
    const count = try io.read(u16);
    const error_text = try io.readText();
    defer std.heap.page_allocator.free(error_text);
    const query = try io.readText();
    defer std.heap.page_allocator.free(query);
    var canvas: types.Canvas = .{
        .chrome = .{ .ratio = ratio, .small = small }, .fact_widths = @splat(0), .action_widths = undefined,
    };
    for (&canvas.action_widths) |*hint| for (hint) |*width| { width.* = try io.read(f32); };
    canvas.range_width = try io.read(f32);
    var history: types.History = .{
        .now_ms = 0, .loaded = true, .items = undefined, .len = count, .page_offset = offset,
        .has_more = flags & 4 != 0, .match_fuzzy = flags & 8 != 0, .enter_runs = flags & 1 != 0, .error_text = error_text,
    };
    const projection: types.Projection = .{
        .history = &history, .prompt = .{ .inspecting_value = flags & 2 != 0 }, .model = .{ .panes = .{ .open = false } },
    };
    const hints = Footer.hints(flags & 2 != 0, flags & 1 != 0);
    try io.write(@as(u8, @intCast(hints.len)));
    for (hints, 0..) |hint, index| {
        try io.writeText(hint.key);
        try io.writeText(hint.word);
        try io.write(@as(u8, @intFromEnum(hint.action)));
        canvas.hint_keys[index] = hint.key;
        canvas.hint_words[index] = hint.word;
    }
    const footer: Footer = .{ .projection = &projection, .layout = .{ .footer = area }, .query = query };
    try footer.footer(&canvas);
    try io.write(@as(u8, 0));
}
pub fn main() !void {
    while (true) switch (io.operation()) {
        -1 => return,
        0 => try frame(),
        else => return error.InvalidOperation,
    };
}
'''


def prepare(repository, output):
    prepare_hint_sources(repository, output)
    source = (repository / 'src/gui/widgets/overlays/HistoryModal.zig').read_text()
    tables = source[source.index('const HintAction = enum'):source.index('fn footer(')]
    tables = tables.replace('fn hints(', 'pub fn hints(', 1)
    footer = modal + tables + function_source(source, 'footer').replace('fn footer(', 'pub fn footer(', 1)
    (output / 'Footer.zig').write_text(footer)
    facade = (output / 'facades.zig').read_text()
    facade = facade.replace('    now_ms: i64,', '''    now_ms: i64,
    len: u16 = 0, page_offset: u32 = 0, has_more: bool = false,
    match_fuzzy: bool = false, enter_runs: bool = false, error_text: []const u8 = "",''')
    facade = facade.replace('    pub fn slice', '    pub fn errorSlice(self: *@This()) []const u8 { return self.error_text; }\n    pub fn slice')
    facade = facade.replace('generation: u64 = 0', 'generation: u64 = 0, inspecting_value: bool = false, pub fn inspecting(self: @This()) bool { return self.inspecting_value; }')
    facade = facade.replace('action_widths: [3][2]f32,', '''action_widths: [4][2]f32,
    hint_keys: [4][]const u8 = @splat(""), hint_words: [4][]const u8 = @splat(""), range_width: f32 = 0,''')
    original_measure = re.search(r'^    pub fn measure\([^\n]+\)[^\n]*\{\n.*?^    \}', facade, re.M | re.S).group(0)
    facade = facade.replace(original_measure, measure.strip())
    facade = facade.replace('    pub fn textAt', fill + '\n    pub fn textAt')
    (output / 'facades.zig').write_text(facade)
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def frame(area=(.25, .5, 1200, 36), ratio=1, small=11, style=0, flags=0, offset=0, count=3,
          error=b'', query=b'', advances=(20, 30, 30, 20, 30, 40, 40, 60), width=150):
    return (struct.pack('<B5fHBBIH', 0, *area, ratio, small, style, flags, offset, count)
            + pack_text(error) + pack_text(query) + struct.pack('<9f', *advances, width))


def fixtures():
    densities = [.5, .8, 1, 1.25, 1.5, 2, 4, 8]
    for ratio, width, style, flags, count in itertools.product(densities, [0, 1, 80, 160, 240, 320, 800, 1400], range(2), range(16), [0, 1, 128]):
        yield frame(area=(.25, .5, width * ratio, 36 * ratio), ratio=ratio, small=round(11 * ratio), style=style,
                    flags=flags, count=count, query=b'git', advances=tuple(value * ratio for value in [20, 30, 30, 20, 30, 40, 40, 60]), width=150 * ratio)
    for offset, count, flags, style, query in itertools.product([0, 128, 2**32-1], [0, 1, 65535], range(16), range(2), [b'', b'git']):
        yield frame(area=(0, 0, 5000, 36), offset=offset, count=count, flags=flags, style=style, query=query)
    for error, width, ratio in itertools.product([b'Cannot paste', b'x' * 128, 'Invalid command…'.encode()], [0, 1, 16, 32, 64, 320, 800], densities):
        yield frame(area=(0, 0, width * ratio, 36 * ratio), ratio=ratio, error=error)
    generator = random.Random(0x41574)
    for _ in range(8000):
        ratio = generator.choice(densities)
        yield frame(area=(generator.uniform(-4, 4), generator.uniform(-4, 4), generator.uniform(0, 2000) * ratio,
                          generator.choice([0, 1, 5, 10, 36, 80]) * ratio), ratio=ratio, small=generator.randrange(1, 257),
                    style=generator.randrange(2), flags=generator.randrange(16), offset=generator.randrange(2**32), count=generator.randrange(65536),
                    query=generator.choice([b'', b'!git', '日本語'.encode()]), error=generator.choice([b'', b'', b'capture failed']),
                    advances=tuple(generator.uniform(0, 160) * ratio for _ in range(8)), width=generator.uniform(0, 300) * ratio)


def main():
    parser = argparse.ArgumentParser(description='Compare history footer labels, fitting and drawing geometry with original Zig methods')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-history-footer-probe', payload, output, 'cpp')
    if expected != actual:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History footer mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_footer_probe.cpp'), Path(__file__).with_name('probe_history_hint.hpp'),
               Path(__file__).with_name('check_history_facts.py'), Path(__file__).with_name('check_history_card.py')]
    sources += [repository / value for value in ['src/gui/widgets/overlays/HistoryModal.zig', 'src/gui/widgets/overlays/HistoryHint.zig',
                'src/gui/widgets/overlays/PaletteRow.zig', 'src/gui/widgets/ChromeMetrics.zig',
                'services/gui-cpp/presentation/history_footer.hpp', 'services/gui-cpp/presentation/history_footer_geometry.hpp',
                'services/gui-cpp/presentation/history_hint_geometry.hpp']]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
                  reference_command=command, source_sha256={str(path.relative_to(repository)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
                  generated_sha256={str(path.relative_to(output)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.glob('*.zig'))},
                  scope='Original footer method, hint tables/selection, HistoryHint and PaletteRow.keycap are retained. Shaping receives premeasured advances, drawing is recorded and Caption records its error box/text as one run. Compares action labels, range formatting, original fitting order, rings, rectangles, clipping and error precedence. Does not validate Caption chunking, native pixels, event routing or performance.')
    (output / 'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Matched',len(cases),'history footer records:',result['output_sha256'])


if __name__ == '__main__':
    main()
