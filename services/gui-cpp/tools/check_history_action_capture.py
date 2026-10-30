"""Compare retained card actions with the original widget dispatcher."""
import argparse
import hashlib
import json
import math
import os
import re
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_history_card import protocol


def prepare(repository, output):
    original = output / 'original'
    original.mkdir()
    identities = {}
    paths = ['src/gui/widgets/interaction/' + name for name in ('Dispatcher.zig', 'Registry.zig', 'Target.zig', 'Id.zig', 'Route.zig', 'key_owner.zig', 'history_action.zig', 'HistoryChoice.zig', 'PathCompletionChoice.zig')]
    paths += ['src/gui/render/GenericPresentedState.zig', 'lib/window/input/PointerEvent.zig']
    for name in paths:
        source = repository / name
        target = original / (name.removeprefix('src/') if name.startswith('src/') else 'window/PointerEvent.zig')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        identities[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    dispatcher = original / 'gui/widgets/interaction/Dispatcher.zig'
    with dispatcher.open('a') as stream:
        stream.write('\npub fn probePointer(self: *Dispatcher, event: Pointer) Route { return self.pointer(event); }\n')
    (original / 'window.zig').write_text('pub const Input = union(enum) { pointer: @import("window/PointerEvent.zig"), key: struct {}, text: struct {} };\n')
    (original / 'keyinput.zig').write_text('''pub fn GenericTable(comptime Owner: type, comptime capacity: usize) type {
    return struct {
        entries: [capacity]struct { owner: Owner, identity: u32 } = undefined,
        len: usize = 0,
        pub fn acquire(_: *@This(), _: u32, _: Owner) bool { return true; }
    };
}
''')
    (original / 'model.zig').write_text('''pub const keybind = struct { pub const max_physical_leases = 64; };
pub const AttachmentId = enum(u64) { invalid = 0, _ };
pub const PromptHistoryScope = enum { global, workspace, cwd, pane };
pub const BarOverflow = struct { pub const capacity = 4 * 64; };
pub const bar_values = struct { pub const max_panel_nodes = 128; };
''')
    (original / 'client.zig').write_text('pub const Intent = enum { unused };\npub const Machines = struct { pub const capacity = 17; };\n')
    (original / 'gfx.zig').write_text('pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };\n')
    (original / 'core.zig').write_text('''pub const max_workspace_list_entries = 64;
pub const max_tabs_per_workspace = 64;
pub const max_agent_snapshot_entries = 64;
pub const max_panes_per_tab = 64;
pub const HistoryAuthorFilter = enum { all, human, agent };
pub const Limit = struct {
    pub fn declare(comptime _: []const u8, comptime _: []const u8, comptime _: usize) @This() { return .{}; }
};
''')
    band = (repository / 'src/gui/widgets/BandHitMap.zig').read_text()
    capacity = next(line for line in band.splitlines() if line.startswith('pub const capacity ='))
    bars = next(line for line in band.splitlines() if line.startswith('const bar_targets ='))
    (original / 'gui/widgets/BandHitMap.zig').write_text('const core = @import("telar-core");\nconst data = @import("model");\nconst client = @import("telar-client");\n' + capacity + '\n' + bars + '\n')
    def value(path, name):
        source = repository / path
        identities[path] = hashlib.sha256(source.read_bytes()).hexdigest()
        match = re.search(r'pub const ' + name + r'\s*=\s*(\d+);', source.read_text())
        assert match, (path, name)
        return int(match.group(1))
    core = original / 'core.zig'
    text = core.read_text()
    for name in ('max_workspace_list_entries', 'max_tabs_per_workspace', 'max_agent_snapshot_entries', 'max_panes_per_tab'):
        text = text.replace('const ' + name + ' = 64;', 'const ' + name + ' = ' + str(value('src/core/schema/types.zig', name)) + ';')
    core.write_text(text)
    model = original / 'model.zig'
    text = model.read_text().replace('max_physical_leases = 64;', 'max_physical_leases = ' + str(value('src/model/input/keybind.zig', 'max_physical_leases')) + ';')
    text = text.replace('capacity = 4 * 64;', 'capacity = 4 * ' + str(value('src/model/bars/model.zig', 'max_bar_nodes')) + ';').replace('max_panel_nodes = 128;', 'max_panel_nodes = ' + str(value('src/model/bars/model.zig', 'max_panel_nodes')) + ';')
    model.write_text(text)
    client = original / 'client.zig'
    client.write_text(client.read_text().replace('capacity = 17;', 'capacity = ' + str(value('src/core/MachineProfiles.zig', 'capacity') + 1) + ';'))
    (original / 'protocol.zig').write_text(protocol.replace('@import("facades.zig").Rect', '@import("gfx").Rect'))
    (original / 'probe.zig').write_text(reference)
    aliases = [('telar-window', 'window.zig'), ('keyinput', 'keyinput.zig'), ('model', 'model.zig'), ('telar-core', 'core.zig'), ('telar-client', 'client.zig'), ('gfx', 'gfx.zig')]
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc']
    for name, _ in aliases:
        command.extend(['--dep', name])
    command.append('-Mroot=' + str(original / 'probe.zig'))
    command.extend('-M' + name + '=' + str(original / file) for name, file in aliases)
    command.append('-femit-bin=' + str(output / 'reference'))
    with (output / 'reference-build.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    (output / 'reference-build.json').write_text(json.dumps(dict(command=command, actual_exit=result.returncode, unchanged_source_sha256=identities, scope='Unchanged original Dispatcher/Registry/Target and presentation state; narrow module facades; private pointer entry adapter appended'), indent=2) + '\n')
    result.check_returncode()


reference = r'''
const std = @import("std");
const D = @import("gui/widgets/interaction/Dispatcher.zig");
const Pointer = @FieldType(@import("telar-window").Input, "pointer");
const io = @import("protocol.zig");
const Action = @import("gui/widgets/interaction/history_action.zig").Action;
pub fn main() !void {
    var dispatcher: D = .{};
    while (true) {
        const incoming = io.operation();
        if (incoming < 0) return;
        const operation: u8 = @intCast(incoming);
        var consumed: u8 = 0;
        var activated: u8 = 0;
        switch (operation) {
            0 => dispatcher = .{},
            1 => {
                const delivered = try io.read(u8) != 0;
                const generation = try io.read(u64);
                _ = dispatcher.begin();
                for (0..3) |_| {
                    const kind = try io.read(u8);
                    const bounds = try io.readRect();
                    const present = try io.read(u8) != 0;
                    const enabled = try io.read(u8) != 0;
                    const action: Action = switch (kind) { 0 => .copy, 1 => .remove, 2 => .visit_pane, else => unreachable };
                    if (present) _ = try dispatcher.add(.{ .id = .{ .generation = generation }, .namespace = 31, .bounds = bounds, .action = .{ .history = action }, .enabled = enabled, .focusable = false });
                }
                dispatcher.seal();
                dispatcher.present(delivered);
            },
            2, 3 => {
                const button: Pointer.Button = @enumFromInt(try io.read(u8));
                const point = [2]f64{ try io.read(f64), try io.read(f64) };
                const result = dispatcher.probePointer(.{ .kind = if (operation == 2) .press else .release, .button = button, .x = point[0], .y = point[1] });
                consumed = @intFromBool(if (operation == 2) dispatcher.captures[@intFromEnum(button)] != null else result.consumed);
                if (operation == 3 and button == .left) {
                    if (result.target) |target| {
                        if (target.enabled and target.contains(point)) activated = switch (target.action.history) { .copy => 1, .remove => 2, .visit_pane => 3, else => unreachable };
                    }
                }
            },
            4 => dispatcher.cancel(),
            else => unreachable,
        }
        var held: u8 = 0;
        for (dispatcher.captures, dispatcher.discarded, 0..) |capture, discarded, index| {
            if (capture != null or discarded) held |= @as(u8, 1) << @intCast(index);
        }
        try io.write(consumed);
        try io.write(activated);
        try io.write(held);
    }
}
'''


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def frame(generation=11, delivered=True, present=7, enabled=7, moved=False, order=(0, 1, 2), overlap=False, rectangles=None):
    result = struct.pack('<BBQ', 1, delivered, generation)
    for action in order:
        bounds = (0 if overlap else action * 20, 0, 10, 10)
        if moved:
            bounds = (100 + bounds[0], 100, 10, 10)
        if rectangles is not None:
            bounds = rectangles[action]
        result += struct.pack('<B4fBB', action, *bounds, bool(present & (1 << action)), bool(enabled & (1 << action)))
    return result


def pointer(operation, button=0, x=5, y=5):
    return struct.pack('<BBdd', operation, button, x, y)


def cases():
    directed = [
        ('replacement', b'\0' + frame() + pointer(2) + frame(moved=True) + pointer(3, x=105, y=105), 1),
        ('reordered', b'\0' + frame() + pointer(2) + frame(moved=True, order=(2, 1, 0)) + pointer(3, x=105, y=105), 1),
        ('disappeared', b'\0' + frame() + pointer(2) + frame(present=6) + frame() + pointer(3), 0),
        ('disabled-press-enabled-release', b'\0' + frame(enabled=6) + pointer(2) + frame() + pointer(3), 1),
        ('disabled', b'\0' + frame() + pointer(2) + frame(enabled=6) + frame() + pointer(3), 0),
        ('generation', b'\0' + frame() + pointer(2) + frame(generation=12) + pointer(3), 0),
        ('failed-frame', b'\0' + frame() + pointer(2) + frame(delivered=False, present=0) + pointer(3), 1),
        ('focus-loss', b'\0' + frame() + pointer(2) + b'\4' + frame() + pointer(3), 0),
        ('outside', b'\0' + frame() + pointer(2) + pointer(3, x=10), 0),
        ('middle', b'\0' + frame() + pointer(2, button=1) + pointer(3, button=1), 0),
        ('right', b'\0' + frame() + pointer(2, button=2) + pointer(3, button=2), 0),
        ('overlap', b'\0' + frame(overlap=True) + pointer(2) + pointer(3), 3),
        ('release-without-press', b'\0' + frame() + pointer(3), 0),
    ]
    for name, payload, expected in directed:
        yield name, payload, expected
    for origin, width in [(f32(0.1), f32(0.2)), (float(1 << 24), 5.0)]:
        rectangles = [(origin, 0, width, 10), (0, 0, 0, 0), (0, 0, 0, 0)]
        middle = origin + width / 2
        right = origin + width
        for index, x in enumerate([origin, math.nextafter(origin, -math.inf), math.nextafter(right, -math.inf), right, math.nextafter(right, math.inf)]):
            payload = b'\0' + frame(present=1, rectangles=rectangles) + pointer(2, x=middle) + pointer(3, x=x)
            yield 'boundary-' + str(origin) + '-' + str(index), payload, int(origin <= x < right)
    randomizer = random.Random(0x190A6)
    for sequence in range(512):
        generation = randomizer.choice([0, 1, 11, (1 << 64) - 1])
        payload = b'\0' + frame(generation)
        physical = [False] * 3
        for _ in range(64):
            kind = randomizer.randrange(5)
            button = randomizer.randrange(3)
            if kind < 2:
                generation = generation if randomizer.randrange(4) else randomizer.getrandbits(64)
                payload += frame(generation, delivered=bool(randomizer.randrange(4)), present=randomizer.randrange(8), enabled=randomizer.randrange(8), moved=bool(randomizer.randrange(2)), order=tuple(randomizer.sample(range(3), 3)), overlap=randomizer.randrange(5) == 0)
            elif kind == 2 and not physical[button]:
                payload += pointer(2, button, randomizer.choice([5, 25, 45, 105, 125, 145]), randomizer.choice([5, 105]))
                physical[button] = True
            elif kind == 3:
                payload += pointer(3, button, randomizer.choice([0, 5, 10, 25, 45, 105, 125, 145]), randomizer.choice([5, 105]))
                physical[button] = False
            else:
                payload += b'\4'
                physical = [False] * 3
        yield 'random-' + str(sequence), payload, None


def operation_count(payload):
    position = 0
    count = 0
    while position < len(payload):
        operation = payload[position]
        position += 1 if operation in (0, 4) else (67 if operation == 1 else 18)
        count += 1
    assert position == len(payload)
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compiler', default='clang++')
    parser.add_argument('--sanitizers', action='store_true')
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    prepare(repository, output)
    candidate = output / 'candidate'
    command = [options.compiler, '-std=c++23', '-O2', '-Wall', '-Wextra', '-Werror', '-I' + str(repository / 'services/gui-cpp'), str(repository / 'services/gui-cpp/tools/history_action_capture_probe.cpp'), '-o', str(candidate)]
    if options.sanitizers:
        command += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    with (output / 'candidate-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    records = list(cases())
    payload = b''.join(data for _, data, _ in records)
    (output / 'input.bin').write_bytes(payload)
    results = []
    for name in ('reference', 'candidate'):
        binary = output / name
        result = subprocess.run([str(binary)], input=payload, capture_output=True, timeout=30)
        (output / (name + '.bin')).write_bytes(result.stdout)
        (output / (name + '.stderr')).write_bytes(result.stderr)
        results.append(dict(name=name, actual_exit=result.returncode, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), output_sha256=hashlib.sha256(result.stdout).hexdigest()))
        assert result.returncode == 0, (name, result.stderr.decode(errors='replace'))
    reference_bytes, candidate_bytes = [(output / (name + '.bin')).read_bytes() for name in ('reference', 'candidate')]
    offset = 0
    observations = []
    for name, data, expected in records:
        size = operation_count(data) * 3
        original = reference_bytes[offset:offset + size]
        current = candidate_bytes[offset:offset + size]
        passed = original == current and len(current) == size
        if expected is not None:
            passed = passed and original[-2] == expected
        observations.append(dict(name=name, passed=passed, operations=size // 3))
        offset += size
    record = dict(sanitizers={name:os.environ.get(name) for name in ('ASAN_OPTIONS','UBSAN_OPTIONS','LSAN_OPTIONS')}, candidate_build=dict(command=command,actual_exit=0,sanitizers_enabled=options.sanitizers), passed=all(entry['passed'] for entry in observations) and len(reference_bytes) == len(candidate_bytes) == offset, executions=results, cases=observations, input_sha256=hashlib.sha256(payload).hexdigest(), scope='Pointer capture and frame-delivery semantics; no native raster or physical-device acceptance')
    (output / 'results.json').write_text(json.dumps(record, indent=2) + '\n')
    assert record['passed'], [entry for entry in observations if not entry['passed']][:8]
    print('Passed', len(records), 'original dispatcher sequences;', offset // 3, 'operations')


if __name__ == '__main__':
    main()
