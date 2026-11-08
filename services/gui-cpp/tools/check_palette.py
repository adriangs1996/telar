import argparse
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_history_card import protocol
from check_notification_center import function_source


facades = r'''
pub const Rect = @import("gfx").Rect;
const Workspaces = struct {
    name: []const u8, branch: []const u8,
    pub fn indexOf(_: *const @This(), _: u64) ?usize { return 0; }
    pub fn nameAt(self: *const @This(), _: usize) []const u8 { return self.name; }
    pub fn branchAt(self: *const @This(), _: usize) []const u8 { return self.branch; }
};
const Tabs = struct { pub fn find(_: *const @This(), _: u64) ?usize { return 0; } };
const Model = struct { tabs: Tabs = .{}, label: []const u8 };
const Agent = struct {
    provider: []const u8, title: []const u8, workspace: []const u8,
    pub fn providerName(self: *const @This()) []const u8 { return self.provider; }
    pub fn sessionTitle(self: *const @This()) []const u8 { return self.title; }
    pub fn workspaceLabel(self: *const @This()) []const u8 { return self.workspace; }
};
const Agents = struct {
    entry: Agent,
    pub fn find(self: *const @This(), _: u64) ?*const Agent { return &self.entry; }
};
pub const Sources = struct { workspaces: *const Workspaces, model: ?*const Model, agents: *const Agents };
pub const tab_label = struct {
    pub fn text(model: *const Model, _: usize) []const u8 { return model.label; }
};
pub const WorkspacesInput = Workspaces;
pub const ModelInput = Model;
pub const AgentsInput = Agents;
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const f = @import("facades.zig");
const Sources = f.Sources;
const tab_label = f.tab_label;
const Prefix = @import("prefix.zig").CommandPalettePrefix;
const Layout = @import("gui/widgets/overlays/PaletteLayout.zig");
const Canvas = @import("gui/widgets/Canvas.zig");
const fuzzy = @import("fuzzy.zig");
const max_label_bytes = 160;
const max_results = 192;
const continuation_mask: u8 = 0b1100_0000;
const continuation_bits: u8 = 0b1000_0000;
const Item = union(enum) { workspace: u64, tab: u64, agent: u64 };
const Results = struct {
    matches: [max_results]struct { item: Item, score: u32 } = undefined,
    len: u8 = 0,
};
const Direction = enum { left, right, up, down };
const CommandAction = union(enum) {
    split_pane: enum { horizontal, vertical }, focus_pane: Direction,
    toggle_pane_fullscreen, close_pane, new_tab, rename_tab, close_tab,
    select_tab_offset: i8, move_tab: enum { previous, next }, new_workspace,
    rename_workspace, toggle_sidebar, toggle_workspace_list, leave_worktree,
    forget_gone_worktrees, enter_copy_mode, history_palette, suggest_command,
    path_picker, machine_picker, select_machine_offset: i8, add_machine,
};
const CommandEntry = struct { action: CommandAction, label: []const u8 };
const CommandResults = struct {
    matches: [entries.len]struct { index: u8, score: u32 } = undefined,
    len: usize = 0,
    pub fn slice(self: *const @This()) []const @TypeOf(self.matches[0]) { return self.matches[0..self.len]; }
};
const core = fuzzy;
const keyinput = @import("keyinput");
const key_label = @import("key_label.zig");
__ENTRIES__
__COLLECT__
__PREFIX_OF__
__QUERY__
__DESCRIBE__
__LAST_BOUNDARY__
__INSERT__
fn queryCase() !void {
    const text = try io.readText();
    try io.write(@intFromEnum(prefixOf(text)));
    try io.writeText(query(text));
}
fn labelCase() !void {
    const kind = try io.read(u8);
    const primary = try io.readText();
    const secondary = try io.readText();
    const third = try io.readText();
    const workspaces: f.WorkspacesInput = .{ .name = primary, .branch = secondary };
    const model: f.ModelInput = .{ .label = primary };
    const agents: f.AgentsInput = .{ .entry = .{ .provider = primary, .title = secondary, .workspace = third } };
    const sources: Sources = .{ .workspaces = &workspaces, .model = &model, .agents = &agents };
    const item: Item = switch (kind) { 0 => .{ .workspace = 1 }, 1 => .{ .tab = 1 }, 2 => .{ .agent = 1 }, else => return error.LabelKind };
    var buffer: [max_label_bytes]u8 = undefined;
    try io.writeText(describe(sources, item, &buffer));
}
fn rankCase() !void {
    const needle = try io.readText();
    const count = try io.read(u16);
    var results: Results = .{};
    for (0..count) |index| {
        const label = try io.readText();
        const score = fuzzy.score(label, needle) orelse continue;
        insert(&results, .{ .tab = index }, score);
    }
    try io.write(@as(u16, results.len));
    for (results.matches[0..results.len]) |match| {
        try io.write(@as(u16, @intCast(match.item.tab)));
        try io.write(match.score);
    }
}
fn catalogueCase() !void {
    const needle = try io.readText();
    var results: CommandResults = .{};
    collect(needle, &results);
    try io.write(@as(u16, @intCast(results.len)));
    for (results.slice()) |match| {
        try io.write(@as(u16, match.index));
        try io.writeText(entries[match.index].label);
        try io.write(match.score);
    }
}
fn readKey() !keyinput.Key {
    const kind = try io.read(u32);
    const character = try io.read(u32);
    const modifiers = try io.read(u32);
    const specials = [_]keyinput.Key.Code{ .up, .down, .left, .right, .home, .end, .delete, .page_up, .page_down, .enter, .escape, .backspace, .tab, .back_tab };
    var storage: [4]u8 = undefined;
    const code: keyinput.Key.Code = if (kind == 0) .{ .char = keyinput.Char.init(storage[0..try std.unicode.utf8Encode(@intCast(character), &storage)]) } else specials[kind - 1];
    return .{ .code = code, .mods = .{ .ctrl = modifiers & 1 != 0, .alt = modifiers & 2 != 0, .shift = modifiers & 4 != 0, .super = modifiers & 8 != 0 } };
}
fn keyLabelCase() !void {
    const style: key_label.Style = @enumFromInt(try io.read(u8));
    const prefixed = try io.read(u8) != 0;
    const prefix = try readKey();
    const key = try readKey();
    var storage: [key_label.max_bytes]u8 = undefined;
    try io.writeText(key_label.chord(&storage, if (prefixed) prefix else null, key, style));
}
fn geometryCase() !void {
    const width = try io.read(u32);
    const height = try io.read(u32);
    const ratio = try io.read(f32);
    const title = try io.read(u16);
    const body = try io.read(u16);
    const small = try io.read(u16);
    const pick = try io.read(u8) != 0;
    const rows = try io.read(u16);
    const suggest = try io.read(u8) != 0;
    const canvas: Canvas = .{ .viewport = .{ width, height }, .chrome = .{ .ratio = ratio, .title = title, .body = body, .small = small } };
    const layout = Layout.measure(&canvas, .{ .pick_rows = if (pick) rows else null, .suggest = suggest });
    for ([_]f.Rect{ layout.viewport, layout.bounds, layout.heading, layout.search, layout.tabs, layout.results, layout.footer }) |area| {
        try io.writeRect(area);
    }
    try io.write(layout.row_height);
    try io.write(layout.agent_height);
    try io.write(layout.group_height);
}
pub fn main() !void {
    while (true) {
        switch (io.operation()) {
            -1 => return,
            1 => try queryCase(),
            2 => try labelCase(),
            3 => try rankCase(),
            4 => try geometryCase(),
            5 => try catalogueCase(),
            6 => try keyLabelCase(),
            else => return error.Operation,
        }
    }
}
'''


def prepare(repository, output):
    widgets = output / 'gui/widgets'
    overlays = widgets / 'overlays'
    overlays.mkdir(parents=True)
    for name in ['ChromeMetrics.zig', 'label_size.zig']:
        shutil.copy2(repository / 'src/gui/widgets' / name, widgets / name)
    shutil.copy2(repository / 'src/gui/widgets/overlays/PaletteLayout.zig', overlays / 'PaletteLayout.zig')
    shutil.copy2(repository / 'src/core/fuzzy.zig', output / 'fuzzy.zig')
    shutil.copy2(repository / 'src/model/state/CommandPalettePrefix.zig', output / 'prefix.zig')
    shutil.copy2(repository / 'src/gui/widgets/overlays/key_label.zig', output / 'key_label.zig')
    (widgets / 'Canvas.zig').write_text('chrome: @import("ChromeMetrics.zig"), viewport: [2]u32,\n')
    (output / 'client.zig').write_text('pub const GuiConfig = struct { font: struct { size: f32 }, chrome: struct { scale: f32 } };\n')
    (output / 'facades.zig').write_text(facades)
    (output / 'protocol.zig').write_text(protocol)
    palette = (repository / 'src/model/state/command_palette.zig').read_text()
    navigation = (repository / 'src/model/state/goto_picker.zig').read_text()
    source = reference
    catalogue = re.search(r'pub const entries = \[_\]CommandEntry\{.*?\n\};', palette, re.DOTALL)
    if catalogue is None:
        raise ValueError('Missing original command palette catalogue')
    source = source.replace('__ENTRIES__', catalogue[0])
    for marker, name, original in [('PREFIX_OF', 'prefixOf', palette), ('QUERY', 'query', palette),
                                   ('DESCRIBE', 'describe', navigation), ('LAST_BOUNDARY', 'lastBoundary', navigation),
                                   ('INSERT', 'insert', navigation), ('COLLECT', 'collect', palette)]:
        source = source.replace('__' + marker + '__', function_source(original, name))
    (output / 'probe.zig').write_text(source)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'gfx', '--dep', 'telar-client', '--dep', 'keyinput',
               f'-Mroot={output / "probe.zig"}', f'-Mgfx={repository / "lib/gfx/root.zig"}',
               f'-Mtelar-client={output / "client.zig"}', f'-Mkeyinput={repository / "lib/keyinput/root.zig"}', f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def text(value):
    return struct.pack('<H', len(value)) + value


def fixtures():
    yield 'query', b'\1' + text(b'')
    for prefix in range(256):
        for suffix in [b'', b'Case @ second', 'contexto é'.encode()]:
            yield 'query', b'\1' + text(bytes([prefix]) + suffix)
    for kind, length, ending in itertools.product(range(3), range(148, 173), ['a', 'é', '中', '🧵']):
        primary = ('a' * length + ending).encode()
        yield 'label', bytes([2, kind]) + text(primary) + text('branch é'.encode()) + text(b'context')
    for kind, parts in itertools.product(range(3), [(b'', b'', b''), (b'provider', b'session', b'context'),
                                                    (b'\x80' * 160, b'', b''), (b'a' * 159 + b'\xff', b'', b'')]):
        yield 'label', bytes([2, kind]) + b''.join(text(part) for part in parts)
    random_source = random.Random(0x54454C4152)
    for needle, count in itertools.product([b'', b'ab', b'zbt', b'Q', 'é'.encode()], [0, 1, 29, 64, 192, 240]):
        labels = [bytes(random_source.choice(b'abcXYZ -_/') for _ in range(random_source.randrange(0, 80))) for _ in range(count)]
        if count:
            labels[0] = b'ab'
        yield 'ranking', b'\3' + text(needle) + struct.pack('<H', count) + b''.join(text(label) for label in labels)
    for labels in [[b'a-b', b'xxab', b'ab', b'aaaab'], [b'x' * 600 + b'ab', b'x' * 601 + b'ab'],
                   [b'ab'] * 240, [b'no match', b'not here']]:
        yield 'ranking', b'\3' + text(b'ab') + struct.pack('<H', len(labels)) + b''.join(text(label) for label in labels)
    repository = Path(__file__).resolve().parents[3]
    catalogue = (repository / 'src/model/state/command_palette.zig').read_text()
    labels = [json.loads(label) for label in re.findall(r'\.label\s*=\s*("(?:[^"\\]|\\.)*")', catalogue)]
    for needle in ['', 'no command could match this phrase', 'SPLIT', 'm t', 'é', '…']:
        yield 'catalogue', b'\5' + text(needle.encode())
    for label in labels:
        for length in range(1, len(label) + 1):
            yield 'catalogue', b'\5' + text(label[:length].encode())
    for _ in range(512):
        label = random_source.choice(labels)
        needle = ''.join(character for character in label if random_source.randrange(3) == 0)
        yield 'catalogue', b'\5' + text(needle.encode())
    chords = [(kind, 0) for kind in range(1, 15)]
    chords.extend((0, character) for character in [*range(128), 0xe9, 0x3a9, 0x4e2d, 0x1f9f5, 0x10ffff])
    for style, prefixed, modifiers, chord in itertools.product(range(2), [False, True], range(16), chords):
        prefix = (0, ord('b'), modifiers)
        yield 'key_label', struct.pack('<BBBIIIIII', 6, style, prefixed, *prefix, *chord, modifiers)
    densities = [0.5, 0.8, 1, 1.25, 1.5, 2, 4, 8]
    sizes = [(0, 0), (1, 1), (2, 3), (160, 90), (320, 200), (640, 464), (900, 300), (1200, 800), (1600, 1000), (65535, 65535)]
    fonts = [(13, 13, 11), (23, 22, 19), (4096, 4096, 4096), (0, 0, 0)]
    for density, size, roles, pick, suggest in itertools.product(densities, sizes, fonts, [None, 0, 1, 3, 8, 64, 65535], [False, True]):
        yield 'geometry', struct.pack('<BIIfHHHBHB', 4, *size, density, *roles, pick is not None, pick or 0, suggest)


def main():
    parser = argparse.ArgumentParser(description='Compare palette queries, labels, fuzzy ranking and physical geometry with the original Zig procedures')
    parser.add_argument('--build-dir', type=Path, default=Path('services/gui-cpp/out'))
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(value for _, value in cases)
    (output / 'input.bin').write_bytes(payload)
    cpp = options.build_dir.resolve() / 'gui-palette-probe'
    reference_run = subprocess.run([str(output / 'original')], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    candidate_run = subprocess.run([str(cpp)], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    (output / 'original-output.bin').write_bytes(reference_run.stdout)
    (output / 'cpp-output.bin').write_bytes(candidate_run.stdout)
    (output / 'original-run.log').write_bytes(reference_run.stderr)
    (output / 'cpp-run.log').write_bytes(candidate_run.stderr)
    if candidate_run.stdout != reference_run.stdout:
        common = min(len(candidate_run.stdout), len(reference_run.stdout))
        offset = next((index for index in range(common) if candidate_run.stdout[index] != reference_run.stdout[index]), common)
        raise AssertionError(f'Palette output differs at byte {offset}; retained outputs in {output}')
    sources = ['src/core/fuzzy.zig', 'src/model/state/command_palette.zig', 'src/model/state/CommandPalettePrefix.zig',
               'src/model/state/goto_picker.zig', 'src/gui/widgets/overlays/PaletteLayout.zig',
               'src/gui/widgets/ChromeMetrics.zig', 'src/gui/widgets/label_size.zig',
               'services/gui-cpp/palette/query.hpp', 'services/gui-cpp/palette/navigation_label.hpp',
               'services/gui-cpp/palette/ranked_matches.hpp', 'services/gui-cpp/presentation/palette_geometry.hpp',
               'services/gui-cpp/tools/palette_probe.cpp', 'services/gui-cpp/config/palette_actions.inc',
               'services/gui-cpp/config/default_bindings.inc', 'dlls/telar-base/include/telar_base/history/search_policy.hpp']
    sources.extend(['services/gui-cpp/input/key_label.hpp', 'src/gui/widgets/overlays/key_label.zig',
                    'lib/keyinput/root.zig', 'lib/keyinput/Key.zig', 'lib/keyinput/Char.zig', 'lib/keyinput/Mods.zig'])
    result = dict(cases=len(cases), cases_by_kind={kind: sum(name == kind for name, _ in cases) for kind in ['query', 'label', 'ranking', 'catalogue', 'key_label', 'geometry']},
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(candidate_run.stdout),
                  output_sha256=hashlib.sha256(candidate_run.stdout).hexdigest(), reference_command=command,
                  candidate_binary_sha256=hashlib.sha256(cpp.read_bytes()).hexdigest(),
                  generated_catalogue_sha256=hashlib.sha256((root / 'services/gui-cpp/config/palette_actions.inc').read_bytes()).hexdigest(),
                  source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in sources},
                  generated_sha256={str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest() for path in output.rglob('*.zig')},
                  scope='Unchanged original prefix/query, describe/lastBoundary, bounded insert, full 29-entry action catalogue and collect, key_label, fuzzy score and PaletteLayout/ChromeMetrics procedures. Record storage uses facades. Byte-exact comparison covers catalogue order, labels, matching scores, both host key-label styles, seven physical rectangles and three row heights. Qt exposes the implemented subset. It does not establish native pixels, visible-row admission, complete palette behavior or comparative performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({name: result[name] for name in ['cases', 'cases_by_kind', 'output_bytes', 'output_sha256']}, indent=2))


if __name__ == '__main__':
    main()
