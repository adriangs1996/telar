import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_notification_center import run


core_source = r'''
__CONSTANTS__
pub const PaneId = enum(u64) { invalid = 0, _ };
pub fn raw(value: PaneId) u64 { return @intFromEnum(value); }
pub const GenericSlotIndex = @import("GenericSlotIndex.zig").Type;
pub const ClientLayoutAxis = enum(u8) { horizontal, vertical };
pub const ClientLayoutNode = union(enum) {
    pane: struct { id: PaneId }, split: struct { axis: ClientLayoutAxis, ratio: u16 },
};
pub const ClientTabLayout = struct { focused_pane: PaneId, fullscreen: bool, nodes: []const ClientLayoutNode };
'''

reference = r'''
const std = @import("std");
const core = @import("telar-core");
const cellgrid = @import("cellgrid");
const Layout = @import("workspace/WorkspaceLayout.zig");
const Snapshot = @import("workspace/LayoutSnapshot.zig");
const Direction = @import("workspace/LayoutDirection.zig").LayoutDirection;
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
    for (std.mem.asBytes(&value)) |byte| if (putchar(byte) < 0) return error.WriteFailed;
}
fn rect() !cellgrid.Rect {
    const x = try read(u16); const y = try read(u16); const width = try read(u16);
    return .{ .x = x, .y = y, .w = width, .h = try read(u16) };
}
fn writeRect(value: cellgrid.Rect) !void {
    try write(value.x); try write(value.y); try write(value.w); try write(value.h);
}
fn readLayout() !Layout {
    const count = try read(u8);
    if (count > core.max_client_layout_tab_nodes) return error.CapacityExceeded;
    var nodes: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    for (nodes[0..count]) |*node| {
        node.* = switch (try read(u8)) {
            0 => .{ .pane = .{ .id = @enumFromInt(try read(u64)) } },
            1 => .{ .split = .{ .axis = @enumFromInt(try read(u8)), .ratio = try read(u16) } },
            else => return error.InvalidNode,
        };
    }
    const focused = first: {
        for (nodes[0..count]) |node| switch (node) { .pane => |pane| break :first pane.id, else => {} };
        return error.EmptyLayout;
    };
    return Layout.fromClientLayoutNodes(.{ .nodes = nodes[0..count], .focused_pane = focused, .fullscreen = false });
}
fn writeLayout(layout: *const Layout) !void {
    var storage: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    const nodes = layout.clientLayoutNodes(&storage);
    try write(@as(u8, @intCast(nodes.len)));
    for (nodes) |node| switch (node) {
        .pane => |pane| { try write(@as(u8, 0)); try write(core.raw(pane.id)); },
        .split => |split| { try write(@as(u8, 1)); try write(@as(u8, @intFromEnum(split.axis))); try write(split.ratio); },
    };
}
fn frame() !void {
    const area = try rect();
    const border = try read(u8); const gap = try read(u8); const fullscreen = try read(u8) != 0;
    const focused: core.PaneId = @enumFromInt(try read(u64));
    var layout = try readLayout();
    layout.metrics = .{ .border = border, .gap = gap };
    layout.focused_pane = focused; layout.fullscreen = fullscreen;
    var snapshot: Snapshot = .{};
    layout.snapshot(area, &snapshot);
    try write(@as(u8, @intFromBool(layout.hasBorders())));
    try write(@as(u8, @intCast(snapshot.views().len)));
    for (snapshot.views()) |view| {
        try write(core.raw(view.pane_id)); try write(view.display_index); try write(@as(u8, @intFromBool(view.focused)));
        try writeRect(view.outer); try writeRect(view.content);
    }
    for (snapshot.views()) |view| {
        for ([_]core.ClientLayoutAxis{ .horizontal, .vertical }) |axis| {
            const result = layout.prospectiveSplit(.{ .pane_id = view.pane_id, .axis = switch(axis) { .horizontal => .horizontal, .vertical => .vertical } }, area);
            try write(@as(u8, @intFromBool(result != null)));
            if (result) |split| { try writeRect(split.existing_content); try writeRect(split.new_content); }
        }
    }
    for ([_]Direction{ .left, .right, .up, .down }) |direction| {
        var copy = layout;
        try write(if (copy.focusDirection(direction, area)) |pane| core.raw(pane) else @as(u64, 0));
    }
    for ([_]Direction{ .left, .right, .up, .down }) |direction| {
        var copy = layout;
        try write(@as(u8, @intFromBool(copy.resizeFocused(direction, area))));
        try writeLayout(&copy);
    }
}
pub fn main() !void {
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        if (operation != 0) return error.InvalidOperation;
        try frame();
    }
}
'''


def prepare(root, work):
    types = (root / 'src/core/schema/types.zig').read_text()
    names = ['max_panes_per_tab', 'max_client_layout_tab_nodes', 'client_layout_ratio_scale', 'min_client_layout_ratio', 'max_client_layout_ratio']
    declarations = [re.search(r'^pub const ' + name + r'[^\n]+;', types, re.M).group(0) for name in names]
    (work / 'core.zig').write_text(core_source.replace('__CONSTANTS__', '\n'.join(declarations)))
    shutil.copy2(root / 'src/core/GenericSlotIndex.zig', work / 'GenericSlotIndex.zig')
    shutil.copytree(root / 'src/model/workspace', work / 'workspace')
    shutil.copy2(root / 'lib/cellgrid/Rect.zig', work / 'Rect.zig')
    (work / 'cellgrid.zig').write_text('pub const Rect = @import("Rect.zig");\n')
    (work / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', '--dep', 'cellgrid', f'-Mroot={work / "probe.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-Mcellgrid={work / "cellgrid.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


def leaves(tree):
    return [node[1] for node in tree if node[0] == 0]


def split(tree, identity, axis, ratio, added):
    index = tree.index((0, identity))
    return tree[:index] + [(1, axis, ratio), (0, identity), (0, added)] + tree[index+1:]


def request(tree, area, border=1, gap=1, focused=1, fullscreen=False):
    payload = struct.pack('<B4HBBBQB', 0, *area, border, gap, fullscreen, focused, len(tree))
    for node in tree:
        payload += struct.pack('<BQ', *node) if node[0] == 0 else struct.pack('<BBH', *node)
    return payload


def fixtures():
    trees = [[(0, 1)], [(1, 0, 5000), (0, 1), (0, 2)], [(1, 1, 5000), (0, 1), (0, 2)]]
    trees += [split(trees[1], 2, 1, 3500, 3), split(trees[2], 1, 0, 7000, 3)]
    for tree in trees:
        for width in [0, 1, 2, 3, 5, 6, 7, 8, 20, 145, 65535]:
            for height in [0, 1, 2, 3, 4, 5, 6, 7, 12, 46]:
                for gap in [0, 1, 2]:
                    for fullscreen in [False, True]:
                        yield request(tree, (0, 0, width, height), gap=gap, focused=leaves(tree)[-1], fullscreen=fullscreen)
    generator = random.Random(0x47524944)
    for _ in range(2400):
        count = generator.choice([1, 2, 3, 5, 8, 16, 32, 64])
        tree = [(0, 1)]
        for identity in range(2, count + 1):
            tree = split(tree, generator.choice(leaves(tree)), generator.randrange(2), generator.choice([1000, 3500, 5000, 6500, 9000]), identity)
        width = generator.choice([0, 1, 2, 6, 20, 145, 320, 2048, 65535])
        height = generator.choice([0, 1, 2, 6, 20, 46, 180, 1024, 65535])
        x = generator.randrange(65536 - width)
        y = generator.randrange(65536 - height)
        yield request(tree, (x, y, width, height), border=generator.choice([0, 1, 2, 8, 255]), gap=generator.choice([0, 1, 2, 8, 255]), focused=generator.choice(leaves(tree)), fullscreen=bool(generator.randrange(2)))


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
    actual = run(options.build_dir.resolve() / 'gui-pane-grid-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Pane grid mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [root / 'src/core/schema/types.zig', root / 'src/core/GenericSlotIndex.zig', root / 'lib/cellgrid/Rect.zig', root / 'services/gui-cpp/application/pane_layout.hpp', root / 'services/gui-cpp/core/cell_rectangle.hpp', root / 'services/gui-cpp/tools/pane_grid_probe.cpp', Path(__file__)]
    sources += sorted((root / 'src/model/workspace').glob('*.zig'))
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), frames=len(cases), input_bytes=len(payload), output_bytes=len(actual), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, generated_sha256={str(path.relative_to(work)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))}, reference_command=command, scope='Unchanged original WorkspaceLayout, LayoutSnapshot, layout_support, Metrics and cellgrid.Rect compute tiled/fullscreen cell views, prospective content bounds, four focus directions and four independent resize results. Real GenericSlotIndex backs original snapshot lookup. Small protocol/identity facades omit runtime/I/O. Tests include collapsed regions, origin offsets, optional gutters/borders, minimum subtree extents, complete 64-pane trees and u16 coordinate limits. Physical display conversion, pane drawing, native input devices and comparative performance are outside this oracle.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'original pane-grid frames:', result['output_sha256'])


if __name__ == '__main__':
    main()
