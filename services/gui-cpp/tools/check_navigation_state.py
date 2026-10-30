import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_pane_grid import core_source, split, leaves


reference = r'''
const std = @import("std");
const core = @import("telar-core");
const Layout = @import("workspace/WorkspaceLayout.zig");
const History = @import("workspace/NavigationHistory.zig");
const Saved = @import("workspace/SavedLayouts.zig");
const SavedLayout = @import("workspace/SavedLayout.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void {
    for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; }
}
fn readLocation() !core.TabLocation {
    const kind = try read(u8); const identity = try read(u64);
    return .{ .workspace = if (kind == 0) .{ .workspace = @enumFromInt(identity) } else .{ .worktree = @enumFromInt(identity) }, .tab_id = @enumFromInt(try read(u64)) };
}
fn writeLocation(location: core.TabLocation) !void {
    switch (location.workspace) {
        .workspace => |identity| { try write(@as(u8, 0)); try write(core.raw(identity)); },
        .worktree => |identity| { try write(@as(u8, 1)); try write(core.raw(identity)); },
    }
    try write(core.raw(location.tab_id));
}
const Input = struct { pane_id: core.PaneId, active: bool, layout: ?Layout };
fn readInput(location: core.TabLocation) !Input {
    const pane_id: core.PaneId = @enumFromInt(try read(u64));
    const focused: core.PaneId = @enumFromInt(try read(u64));
    const active = try read(u8) != 0;
    const fullscreen = try read(u8) != 0;
    if (try read(u8) == 0) { return .{ .pane_id = pane_id, .active = active, .layout = null }; }
    const count = try read(u8);
    if (count > core.max_client_layout_tab_nodes) { return error.CapacityExceeded; }
    var nodes: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    for (nodes[0..count]) |*node| {
        node.* = switch (try read(u8)) {
            0 => .{ .pane = .{ .id = @enumFromInt(try read(u64)) } },
            1 => .{ .split = .{ .axis = @enumFromInt(try read(u8)), .ratio = try read(u16) } },
            else => return error.InvalidNode,
        };
    }
    return .{ .pane_id = pane_id, .active = active, .layout = try Layout.fromClientLayoutNodes(.{ .location = location, .focused_pane = focused, .fullscreen = fullscreen, .nodes = nodes[0..count] }) };
}
fn writeLayout(layout: *const Layout) !void {
    try write(core.raw(layout.focused_pane)); try write(@as(u8, @intFromBool(layout.fullscreen)));
    var storage: [core.max_client_layout_tab_nodes]core.ClientLayoutNode = undefined;
    const nodes = layout.clientLayoutNodes(&storage);
    try write(@as(u8, @intCast(nodes.len)));
    for (nodes) |node| switch (node) {
        .pane => |pane| { try write(@as(u8, 0)); try write(core.raw(pane.id)); },
        .split => |branch| { try write(@as(u8, 1)); try write(@as(u8, @intFromEnum(branch.axis))); try write(branch.ratio); },
    };
}
fn writeHistory(history: *const History, location: core.WorkspaceLocation) !void {
    const value = history.find(location); try write(@as(u8, @intFromBool(value != null)));
    if (value) |bookmark| {
        try writeLocation(bookmark.location); try write(core.raw(bookmark.pane_id));
        try write(@as(u8, @intFromBool(bookmark.tab_layout != null)));
        if (bookmark.tab_layout) |layout| { try writeLayout(&layout); }
    }
}
fn writeSaved(value: ?SavedLayout) !void {
    try write(@as(u8, @intFromBool(value != null)));
    if (value) |saved| {
        try writeLocation(saved.location); try write(core.raw(saved.pane_id));
        try write(@as(u8, @intFromBool(saved.workspace_active))); try writeLayout(&saved.layout);
    }
}
pub fn main() !void {
    var history: History = .{}; var saved: Saved = .{};
    while (true) {
        const operation = getchar(); if (operation < 0) { break; }
        const location = try readLocation(); var admitted = true;
        switch (operation) {
            0 => { history = .{}; saved = .{}; },
            1 => { const input = try readInput(location); history.remember(.{ .location = location, .pane_id = input.pane_id, .tab_layout = input.layout }); },
            2 => history.forget(location.workspace),
            3, 4 => {
                const input = try readInput(location);
                const value: SavedLayout = .{ .location = location, .pane_id = input.pane_id, .workspace_active = input.active, .layout = input.layout orelse .{} };
                if (operation == 3) { saved.remember(value) catch { admitted = false; }; } else { saved.retain(value); }
            },
            5 => saved.forget(location),
            6 => {},
            else => return error.UnknownOperation,
        }
        try write(@as(u8, @intFromBool(admitted)));
        try writeHistory(&history, location.workspace); try writeSaved(saved.find(location));
        try write(@as(u16, @intCast(saved.count))); try write(@as(u16, @intCast(saved.node_total)));
        for (saved.location[0..saved.count]) |retained| { try writeLocation(retained); try writeSaved(saved.find(retained)); }
    }
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(repository, output):
    types = (repository / 'src/core/schema/types.zig').read_text()
    names = ['max_panes_per_tab', 'max_client_layout_tab_nodes', 'client_layout_ratio_scale', 'min_client_layout_ratio', 'max_client_layout_ratio', 'max_panes', 'max_workspace_list_entries', 'max_client_layout_tabs', 'max_client_layout_nodes']
    declarations = [re.search(r'^pub const ' + name + r'\b[^\n]+;', types, re.M).group(0) for name in names]
    core = core_source.replace('__CONSTANTS__', '\n'.join(declarations))
    core = core.replace('pub fn raw(value: PaneId)', 'pub fn raw(value: anytype)')
    locations = '''pub const WorkspaceId = enum(u64) { invalid = 0, _ };
pub const WorktreeId = enum(u64) { invalid = 0, _ };
pub const TabId = enum(u64) { invalid = 0, _ };
pub const WorkspaceLocation = union(enum) { workspace: WorkspaceId, worktree: WorktreeId };
pub const TabLocation = struct { workspace: WorkspaceLocation, tab_id: TabId };
'''
    core = core.replace('pub const ClientTabLayout = struct { ', locations + 'pub const ClientTabLayout = struct { location: TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) }, ')
    (output / 'core.zig').write_text(core)
    (output / 'model.zig').write_text('pub const WorkspaceLayout = @import("workspace/WorkspaceLayout.zig");\npub const SavedLayout = @import("workspace/SavedLayout.zig");\n')
    shutil.copytree(repository / 'src/model/workspace', output / 'workspace')
    shutil.copy2(repository / 'src/core/GenericSlotIndex.zig', output / 'GenericSlotIndex.zig')
    shutil.copy2(repository / 'lib/cellgrid/Rect.zig', output / 'Rect.zig')
    (output / 'cellgrid.zig').write_text('pub const Rect = @import("Rect.zig");\n')
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', '--dep', 'cellgrid', '-Mroot=' + str(output / 'probe.zig'), '-Mtelar-core=' + str(output / 'core.zig'), '-Mcellgrid=' + str(output / 'cellgrid.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def command(operation, location, tree=None, pane_id=0, focus=0, active=False, fullscreen=False):
    result = struct.pack('<BBQQ', operation, *location)
    if operation in [1, 3, 4]:
        result += struct.pack('<QQBBB', pane_id, focus, active, fullscreen, tree is not None)
        if tree is not None:
            result += struct.pack('<B', len(tree))
            for node in tree:
                result += struct.pack('<BQ', *node) if node[0] == 0 else struct.pack('<BBH', *node)
    return result


def fixtures():
    cases = [command(0, (0, 1, 1))]
    for identity in range(1, 73):
        cases.append(command(1, (0, identity, identity), [(0, identity)], identity, identity, fullscreen=bool(identity % 2)))
    cases.extend(command(6, (0, identity, identity)) for identity in range(1, 73))
    cases.extend([command(1, (0, 1, 90), [(0, 900)], 900, 900), command(2, (0, 2, 2)), command(1, (0, 73, 73), pane_id=901), command(2, (0, 3, 3)), command(1, (1, 1, 1), [(0, 902)], 902, 902)])
    cases.extend(command(6, (kind, identity, identity)) for kind in [0, 1] for identity in range(1, 75))
    cases.append(command(0, (0, 1, 1)))
    for identity in range(1, 261):
        cases.append(command(3, (0, identity, identity), [(0, identity)], identity, identity, active=bool(identity % 2)))
    cases.extend([command(4, (1, 1, 261), [(0, 1000)], 1000, 1000), command(5, (0, 100, 100))])
    randomizer = random.Random(0x4E415649)

    def tree(count, first):
        nodes = [(0, first)]
        for identity in range(first + 1, first + count):
            nodes = split(nodes, randomizer.choice(leaves(nodes)), randomizer.randrange(2), randomizer.choice([1000, 3500, 5000, 6500, 9000]), identity)
        return nodes

    for identity in [20, 21, 999]:
        nodes = tree(64, identity * 100)
        cases.append(command(3, (0, identity, identity), nodes, leaves(nodes)[0], leaves(nodes)[-1], fullscreen=True))
    nodes = tree(64, 100000)
    cases.append(command(4, (0, 1000, 1000), nodes, leaves(nodes)[0], leaves(nodes)[-1]))
    cases.append(command(3, (1, 1001, 1001)))
    cases.extend(command(6, (0, identity, identity)) for identity in range(1, 261))
    for _ in range(4096):
        operation = randomizer.choices([0, 1, 2, 3, 4, 5, 6], [1, 20, 10, 25, 22, 10, 12])[0]
        location = (randomizer.randrange(2), randomizer.randrange(1, 91), randomizer.randrange(1, 13))
        if operation in [1, 3, 4]:
            nodes = None if randomizer.randrange(12) == 0 else tree(randomizer.choice([1, 1, 1, 2, 3, 8, 16, 32, 64]), randomizer.randrange(1, 10000))
            pane_id = randomizer.choice(leaves(nodes)) if nodes else randomizer.randrange(1, 10000)
            focus = randomizer.choice(leaves(nodes)) if nodes else 0
            cases.append(command(operation, location, nodes, pane_id, focus, active=bool(randomizer.getrandbits(1)), fullscreen=bool(randomizer.getrandbits(1))))
        else:
            cases.append(command(operation, location))
    return cases


def frames(data, count):
    offset = 0

    def layout():
        nonlocal offset
        nodes = data[offset + 9]
        offset += 10
        for _ in range(nodes):
            tag = data[offset]
            assert tag in [0, 1]
            offset += 9 if tag == 0 else 4

    def saved():
        nonlocal offset
        present = data[offset]
        offset += 1
        if present:
            offset += 17 + 8 + 1
            layout()

    spans = []
    for _ in range(count):
        start = offset
        offset += 1
        history = data[offset]
        offset += 1
        if history:
            offset += 17 + 8
            present = data[offset]
            offset += 1
            if present:
                layout()
        saved()
        rows, = struct.unpack_from('<H', data, offset)
        offset += 4
        for _ in range(rows):
            offset += 17
            saved()
        assert offset <= len(data)
        spans.append((start, offset))
    assert offset == len(data)
    return spans


def main():
    parser = argparse.ArgumentParser(description='Compare navigation history and bounded saved layouts against whole original Zig modules')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    reference_command = prepare(repository, output)
    cases = fixtures()
    requests = b''.join(cases)
    (output / 'input.bin').write_bytes(requests)
    binary = options.build_dir.resolve() / 'gui-navigation-state-probe'
    results = {}
    for kind, executable in [('original', output / 'original'), ('cpp', binary)]:
        result = subprocess.run([str(executable)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        results[kind] = result.stdout
    spans = {kind:frames(data, len(cases)) for kind, data in results.items()}
    differences = []
    for index, request in enumerate(cases):
        records = {kind:data[slice(*spans[kind][index])] for kind, data in results.items()}
        if records['original'] != records['cpp']:
            differences.append(dict(index=index, request=request.hex(), bytes={kind:len(data) for kind, data in records.items()}, sha256={kind:sha(data) for kind, data in records.items()}, prefix={kind:data[:96].hex() for kind, data in records.items()}))
    (output / 'differences.json').write_text(json.dumps(differences, indent=2) + '\n')
    sources = ['src/core/schema/types.zig', 'src/core/GenericSlotIndex.zig', 'lib/cellgrid/Rect.zig', 'services/gui-cpp/application/navigation_history.hpp', 'services/gui-cpp/application/saved_layouts.hpp', 'services/gui-cpp/application/pane_layout.hpp', 'services/gui-cpp/tools/navigation_state_probe.cpp', 'services/gui-cpp/tools/check_navigation_state.py', 'services/gui-cpp/tools/check_pane_grid.py']
    sources.extend(str(path.relative_to(repository)) for path in sorted((repository / 'src/model/workspace').glob('*.zig')))
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), operations=len(cases), different_operations=len(differences), input_bytes=len(requests), output_bytes={kind:len(data) for kind, data in results.items()}, input_sha256=sha(requests), output_sha256={kind:sha(data) for kind, data in results.items()}, source_sha256={name:sha((repository / name).read_bytes()) for name in sources}, generated_sha256={str(path.relative_to(output)):sha(path.read_bytes()) for path in sorted(output.rglob('*.zig'))}, reference_command=reference_command, binary_sha256=sha(binary.read_bytes()), sanitizer_environment={key:os.environ.get(key) for key in ['ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS']}, scope='Whole unchanged original NavigationHistory, Bookmark, SavedLayouts, SavedLayout and WorkspaceLayout family with original node loader/encoder, Metrics, Rect and GenericSlotIndex. Only protocol IDs/constants and model value-type exports are facades. Stateful comparison includes queried bookmark target/layout, saved pane and focus, fullscreen, active flag, every retained row/tree/order and shared-pool counts after each operation. Extra geometry metrics/revision, I/O scheduling, full Session handoff and native rendering are outside this oracle.')
    (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({key:record[key] for key in ['operations','different_operations','input_sha256','output_sha256']}))
    assert not differences


if __name__ == '__main__':
    main()
