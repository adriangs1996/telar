import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_notification_center import run
from check_task_labels import function_source


reference = r'''
const std = @import("std");
const Canvas = @import("gui/widgets/Canvas.zig");
const Chrome = @import("gui/widgets/ChromeMetrics.zig");
const CardGeometry = @import("gui/widgets/CardGeometry.zig");
const Regions = @import("gui/widgets/SidebarRegions.zig");
const WorkspaceRow = @import("gui/widgets/WorkspaceRow.zig");
const Rect = @import("gfx").Rect;
__SCROLLBAR_WIDTH__
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
fn writeRect(bounds: Rect) !void {
    try write(bounds.x);
    try write(bounds.y);
    try write(bounds.width);
    try write(bounds.height);
}
fn cardWidth(canvas: *const Canvas, geometry: CardGeometry, width: f32) f32 {
    const list = struct { bounds: Rect }{ .bounds = .{ .x = 0, .y = 0, .width = width, .height = 0 } };
    __SCROLLBAR__
    __CARD_WIDTH__
    return card_width;
}
fn frame() !void {
    const font = try read(f32);
    const text_scale = try read(f32);
    const density = try read(f32);
    const area = try readRect();
    const count = try read(u16);
    const machines = try read(u8) != 0;
    const chrome = Chrome.resolve(.{ .font = .{ .size = font }, .chrome = .{ .scale = text_scale } }, density);
    const canvas: Canvas = .{ .chrome = chrome };
    const regions = try Regions.resolve(&canvas, area, count, machines);
    const card = CardGeometry.derive(chrome, .{ .cell_width = 9 });
    try write(chrome.ratio);
    try write(chrome.title);
    try write(chrome.body);
    try write(chrome.small);
    try write(WorkspaceRow.height(&canvas));
    for ([_]Rect{ regions.machines, regions.projects_header, regions.projects, regions.agents_header, regions.agents }) |bounds| {
        try writeRect(bounds);
    }
    for ([_]f32{ card.small_row, card.title_row, card.scale, card.height(), card.compactHeight(), card.pitch(), cardWidth(&canvas, card, area.width) }) |value| {
        try write(value);
    }
    for ([_]f32{ CardGeometry.padding_x, CardGeometry.padding_y, CardGeometry.spacing, CardGeometry.radius, CardGeometry.gap, CardGeometry.mark_size, CardGeometry.compact_padding_y, CardGeometry.task_indent, CardGeometry.group_gap }) |length| {
        try write(card.px(length));
    }
    for (0..3) |index| try writeRect(card.row(area, @intCast(index)));
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


def prepare(root, work):
    widgets = work / 'gui/widgets'
    widgets.mkdir(parents=True)
    image = work / 'gui/image'
    image.mkdir()
    for name in ['ChromeMetrics.zig', 'CardGeometry.zig', 'SidebarRegions.zig', 'label_size.zig']:
        shutil.copy2(root / 'src/gui/widgets' / name, widgets / name)
    shutil.copy2(root / 'src/gui/image/SpriteSize.zig', image / 'SpriteSize.zig')
    (work / 'gui/TerminalMetrics.zig').write_text('cell_width: u32,\n')
    (widgets / 'Bands.zig').write_text('')
    (widgets / 'Canvas.zig').write_text('chrome: @import("ChromeMetrics.zig"),\n')
    height = function_source((root / 'src/gui/widgets/WorkspaceRow.zig').read_text(), 'height')
    (widgets / 'WorkspaceRow.zig').write_text('const Canvas = @import("Canvas.zig");\n' + height + '\n')
    (work / 'client.zig').write_text('pub const GuiConfig = struct { font: struct { size: f32 }, chrome: struct { scale: f32 } };\npub const FleetCard = enum { agent, task_full, task_compact };\n')
    sidebar = (root / 'src/gui/widgets/Sidebar.zig').read_text()
    source = reference
    for marker, expression in [
        ('__SCROLLBAR_WIDTH__', r'^pub const scrollbar_width[^\n]+;$'),
        ('__SCROLLBAR__', r'^    const scrollbar = canvas\.chrome\.px\(scrollbar_width\);$'),
        ('__CARD_WIDTH__', r'^    const card_width = [^\n]+;$'),
    ]:
        matches = re.findall(expression, sidebar, re.MULTILINE)
        if not matches or len(set(matches)) != 1:
            raise RuntimeError(f'Original sidebar declaration is ambiguous: {marker}')
        source = source.replace(marker, matches[0])
    (work / 'probe.zig').write_text(source)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'gfx', '--dep', 'telar-client', f'-Mroot={work / "probe.zig"}',
        f'-Mgfx={root / "lib/gfx/root.zig"}', f'-Mtelar-client={work / "client.zig"}',
        f'-femit-bin={work / "original"}',
    ]
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


def request(font, text_scale, density, area, count, machines):
    return struct.pack('<B7fHB', 0, font, text_scale, density, *area, count, machines)


def fixtures():
    fonts = [6, 7.5, 12, 15, 16, 17, 32, 64, 96]
    densities = [0.5, 0.8, 1, 1.25, 1.5, 2, 4, 8]
    text_scales = [0.5, 0.8, 1, 2]
    counts = [0, 1, 2, 128]
    areas = [(0, 0, 500, 864), (0.25, 0.75, 280, 180), (100, 50, 52, 96), (0, 0, 0, 0), (0, 0, 16, 48)]
    for font, text_scale, density, count, area in itertools.product(fonts, text_scales, densities, counts, areas):
        physical = tuple(value * density for value in area)
        yield request(font, text_scale, density, physical, count, False)
        yield request(font, text_scale, density, physical, count, True)
    generator = random.Random(0x51DEBA4)
    for index in range(6000):
        area = (generator.choice([0, 0.125, 100.25, -0.75]), generator.choice([0, 0.25, 50.75]), generator.choice([0, 1, 12, 52, 160, 280, 500, 799.25]), generator.choice([0, 1, 16, 29, 48, 64, 96, 128, 512, 864, 1200.75]))
        yield request(generator.choice(fonts), generator.choice(text_scales), generator.choice(densities), area, generator.choice(counts), bool(generator.randrange(2)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command = prepare(root, work)
    cases = list(fixtures())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-sidebar-geometry-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Sidebar geometry mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [root / 'src/gui/widgets' / name for name in ['SidebarRegions.zig', 'ChromeMetrics.zig', 'CardGeometry.zig', 'WorkspaceRow.zig', 'Sidebar.zig', 'label_size.zig']]
    sources += [root / 'src/gui/image/SpriteSize.zig', Path(__file__), Path(__file__).with_name('sidebar_geometry_probe.cpp'), Path(__file__).with_name('probe_geometry.hpp')]
    sources += [root / 'services/gui-cpp/presentation' / name for name in ['agent_card_geometry.hpp', 'sidebar_geometry.hpp']]
    sources += [root / 'services/gui-cpp/core/metrics.hpp', root / 'services/gui-cpp/core/configuration.hpp']
    sources += sorted((root / 'lib/gfx').glob('*.zig'))
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), frames=len(cases),
        input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))},
        reference_command=command,
        scope='Unchanged original ChromeMetrics, CardGeometry, SidebarRegions and gfx.Layout; original WorkspaceRow.height and sidebar width declarations are extracted unchanged. Canvas, terminal metric and configuration storage use recording facades. Compares physical text roles, workspace height, five list rectangles, card heights, pitch, width, nine rounded insets and three text rows byte for byte. Covers eight densities, font/text scale combinations, small/empty viewports, machine header admission and fractional coordinates. Does not prove native projection, raster output, interaction or performance parity.',
    )
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', result['frames'], 'sidebar/card geometry frames:', result['output_sha256'])


if __name__ == '__main__':
    main()
