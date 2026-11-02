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

from check_notification_center import run


reference = r'''
const std = @import("std");
const Rect = @import("gfx").Rect;
const Chrome = @import("gui/widgets/ChromeMetrics.zig");
const Metrics = @import("gui/widgets/overlays/HistoryModalMetrics.zig");
const Layout = @import("gui/widgets/overlays/HistoryModalLayout.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
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
fn readRect() !Rect {
    const x = try read(f32);
    const y = try read(f32);
    const width = try read(f32);
    return .{ .x = x, .y = y, .width = width, .height = try read(f32) };
}
fn writeRect(area: Rect) !void {
    try write(area.x);
    try write(area.y);
    try write(area.width);
    try write(area.height);
}
fn frame() !void {
    const viewport = try readRect();
    const ratio = try read(f32);
    const body = try read(u16);
    const small = try read(u16);
    const status_bar = try read(u32);
    const cell_height = try read(u32);
    const inspecting = try read(u8) != 0;
    const offset = try read(f32);
    const metrics: Metrics = .{
        .viewport = viewport,
        .chrome = Chrome{ .ratio = ratio, .body = body, .small = small, .status_bar = status_bar },
        .terminal = .{ .cell_height = cell_height },
    };
    var layout = Layout.measure(metrics, inspecting);
    layout.offsetY(offset);
    for ([_]Rect{ layout.viewport, layout.bounds, layout.header, layout.results, layout.inspection, layout.search, layout.footer, layout.inspectionContent(metrics), layout.inspectionActions(metrics) }) |area| {
        try writeRect(area);
    }
    try write(layout.row_height);
    try write(layout.group_height);
    try write(@as(u8, @intFromBool(layout.compact)));
}
pub fn main() !void {
    while (true) {
        switch (getchar()) {
            -1 => return,
            0 => try frame(),
            else => return error.InvalidOperation,
        }
    }
}
'''


def prepare(repository, output):
    widgets = output / 'gui/widgets'
    overlays = widgets / 'overlays'
    overlays.mkdir(parents=True)
    for name in ['HistoryModalLayout.zig', 'HistoryModalMetrics.zig']:
        shutil.copyfile(repository / 'src/gui/widgets/overlays' / name, overlays / name)
    for name in ['ChromeMetrics.zig', 'label_size.zig']:
        shutil.copyfile(repository / 'src/gui/widgets' / name, widgets / name)
    (widgets / 'Canvas.zig').write_text('chrome: @import("ChromeMetrics.zig"), metrics: @import("../TerminalMetrics.zig"), viewport: [2]u32,\n')
    (output / 'gui/TerminalMetrics.zig').write_text('cell_height: u32,\n')
    (output / 'client.zig').write_text('pub const GuiConfig = struct { font: struct { size: f32 }, chrome: struct { scale: f32 } };\n')
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'gfx', '--dep', 'telar-client',
               f'-Mroot={output / "probe.zig"}', f'-Mgfx={repository / "lib/gfx/root.zig"}',
               f'-Mtelar-client={output / "client.zig"}', f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def request(area, ratio, body, small, status_bar, cell_height, inspecting, offset):
    return struct.pack('<B5fHHIIBf', 0, *area, ratio, body, small, status_bar, cell_height, inspecting, offset)


def fixtures():
    densities = [.5, .8, 1, 1.25, 1.5, 2, 4, 8]
    sizes = [(0, 0), (1, 1), (320, 200), (420, 260), (899, 900), (900, 900),
             (901, 900), (1200, 800), (1600, 1000), (2400, 1600)]
    for density, size, inspecting, offset in itertools.product(densities, sizes, [False, True], [0, .125, 12]):
        area = (0, 0, size[0] * density, size[1] * density)
        yield request(area, density, max(6, round(13 * density)), max(6, round(11 * density)),
                      round(26 * density), round(20 * density), inspecting, offset * density)
    generator = random.Random(0x41570)
    for _ in range(12000):
        density = generator.choice(densities)
        area = (generator.choice([0, .25, -1]), generator.choice([0, .5, 1]),
                generator.uniform(0, 2400) * density, generator.uniform(0, 1800) * density)
        yield request(area, density * generator.choice([.5, 1, 1.1, 2]), generator.randint(6, 256),
                      generator.randint(6, 256), generator.choice([0, 26, 32, 208]),
                      generator.randint(0, 512), bool(generator.randrange(2)), generator.uniform(-12, 12))


def main():
    parser = argparse.ArgumentParser(description='Compare history panel geometry with the unchanged original Zig implementation')
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
    actual = run(options.build_dir.resolve() / 'gui-history-geometry-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History geometry mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_geometry_probe.cpp'),
               repository / 'services/gui-cpp/presentation/history_modal_geometry.hpp',
               repository / 'services/gui-cpp/core/metrics.hpp', repository / 'services/gui-cpp/core/geometry.hpp',
               repository / 'src/gui/widgets/overlays/HistoryModalLayout.zig',
               repository / 'src/gui/widgets/overlays/HistoryModalMetrics.zig',
               repository / 'src/gui/widgets/ChromeMetrics.zig', repository / 'src/gui/widgets/label_size.zig']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), frames=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual),
                  output_sha256=hashlib.sha256(actual).hexdigest(), reference_command=command,
                  source_sha256={str(path.relative_to(repository)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
                  generated_sha256={str(path.relative_to(output)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.rglob('*.zig'))},
                  scope='Unchanged original HistoryModalLayout measure, offsetY, inspectionContent and inspectionActions with original ChromeMetrics rowHeight. Canvas, terminal and configuration storage use facades. Nine physical rectangles, two row heights and compact admission match byte for byte across eight densities, empty/small/narrow/wide viewports, large font rows, inspector transitions and entrance offsets. This checks geometry, not native raster output, complete history behavior or comparative performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'history geometry frames:', result['output_sha256'])


if __name__ == '__main__':
    main()
