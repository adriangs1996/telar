import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_history_card import protocol
from check_machine_profiles import text
from check_notification_center import function_source


model = r'''
pub const RuntimeLink = struct { __PHASE__ };
pub const Status = enum { ready, needs_input };
pub const Metrics = struct { cpu_percent: u8, cpu_count: u16, memory_used_decigib: u16, memory_total_decigib: u16 };
pub const ClientModel = struct {
    runtime_link: struct { phase: RuntimeLink.Phase, setup_repairs: bool },
    system_metrics_revision: u64,
    agent_revision: u64,
    workspace_list_snapshot: struct { revision: u64 },
    system_metrics: ?Metrics,
    agent_snapshot: Snapshot,
};
pub const Snapshot = struct {
    rows: [1]struct { status: Status },
    pub fn slice(self: *const Snapshot) []const @TypeOf(self.rows[0]) { return &self.rows; }
};
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const Machines = @import("machines/Machines.zig");
const Results = @import("machines/MachineResults.zig");
const picker = @import("machines/machine_picker.zig");
const Row = @import("machines/MachineRow.zig");
const core = @import("telar-core");
const data = @import("model");
const pacing = @import("pacing");
const gpa = std.heap.page_allocator;
fn writeRows(machines: *const Machines) !void {
    try io.write(machines.revision);
    try io.write(machines.active);
    try io.write(@as(u8, @intCast(machines.count())));
    try io.write(@as(u8, @intFromBool(machines.attentionElsewhere())));
    for (0..Machines.capacity) |index| {
        const slot: u8 = @intCast(index);
        try io.write(@as(u8, @intFromBool(machines.used[slot])));
        try io.write(machines.generation[slot]);
        try io.write(@intFromEnum(machines.id[slot]));
        try io.writeText(machines.label(slot));
        try io.writeText(machines.destination(slot));
        try io.writeText(machines.color(slot) orelse "");
        try io.writeText(machines.telarPath(slot) orelse "");
        try io.write(@as(u8, @intFromBool(machines.enabled[slot])));
        try io.write(@as(u8, @intFromBool(machines.pinned[slot])));
        try io.write(@as(u8, @intFromBool(machines.live[slot])));
        try io.write(@intFromEnum(machines.phase[slot]));
        try io.write(@as(u8, @intFromBool(machines.needs_setup[slot])));
        try io.write(@as(u8, @intFromBool(machines.attention[slot])));
        try io.write(@as(u16, if (machines.cpu_percent[slot]) |cpu| cpu else 256));
        try io.write(machines.cpu_count[slot]);
        try io.write(machines.memory_used_decigib[slot]);
        try io.write(machines.memory_total_decigib[slot]);
        try io.write(machines.sampled_ns[slot]);
        try io.write(machines.metrics_revision[slot]);
        try io.write(machines.agent_revision[slot]);
        try io.write(machines.workspace_revision[slot]);
    }
}
fn fields(machines: *Machines, slot: ?u8) !void {
    const id = try io.read(u64);
    const label = try io.readText();
    defer gpa.free(label);
    const destination = try io.readText();
    defer gpa.free(destination);
    const color = try io.readText();
    defer gpa.free(color);
    const enabled = try io.read(u8) != 0;
    const program = try io.readText();
    defer gpa.free(program);
    const row: Row = .{ .id = @enumFromInt(id), .label = label, .destination = destination, .color = color, .enabled = enabled, .telar_path = program };
    if (slot) |chosen| {
        machines.update(chosen, row);
        try io.write(chosen);
    } else {
        const wanted = try io.read(u8);
        try io.write(try machines.add(row, if (wanted == 255) null else wanted));
    }
}
fn summarize(machines: *Machines) !void {
    const slot = try io.read(u8);
    const phase: data.RuntimeLink.Phase = @enumFromInt(try io.read(u8));
    const setup = try io.read(u8) != 0;
    const attention = try io.read(u8) != 0;
    const has_metrics = try io.read(u8) != 0;
    const metrics: data.Metrics = .{ .cpu_percent = try io.read(u8), .cpu_count = try io.read(u16), .memory_used_decigib = try io.read(u16), .memory_total_decigib = try io.read(u16) };
    const metrics_revision = try io.read(u64);
    const agent_revision = try io.read(u64);
    const workspace_revision = try io.read(u64);
    pacing.clock.now_ns = try io.read(u64);
    const state: data.ClientModel = .{
        .runtime_link = .{ .phase = phase, .setup_repairs = setup },
        .system_metrics_revision = metrics_revision, .agent_revision = agent_revision,
        .workspace_list_snapshot = .{ .revision = workspace_revision },
        .system_metrics = if (has_metrics) metrics else null,
        .agent_snapshot = .{ .rows = .{.{ .status = if (attention) .needs_input else .ready }} },
    };
    try io.write(@as(u8, @intFromBool(machines.summarize(slot, &state, std.Io.Threaded.global_single_threaded.io()))));
}
fn operate(operation: i32, machines: *Machines) !void {
    switch (operation) {
        1 => machines.* = .{},
        2 => try fields(machines, null),
        3 => try fields(machines, try io.read(u8)),
        4 => machines.remove(try io.read(u8)),
        5 => { const slot = try io.read(u8); machines.live[slot] = try io.read(u8) != 0; },
        6 => {
            const slot = try io.read(u8);
            const changed = slot != machines.active and machines.shown(slot) and machines.live[slot];
            if (changed) { machines.active = slot; machines.revision +%= 1; }
            try io.write(@as(u8, @intFromBool(changed)));
        },
        7 => {
            const slot = try io.read(u8);
            machines.pinned[slot] = machines.id[slot] == .invalid or !machines.enabled[slot];
            machines.enabled[slot] = true;
            machines.revision +%= 1;
        },
        8 => machines.pinned[try io.read(u8)] = false,
        9 => try summarize(machines),
        10 => {
            const query = try io.readText();
            defer gpa.free(query);
            var results: Results = .{};
            picker.collect(machines, query, &results);
            try io.write(results.len);
            for (results.slice(), results.scores[0..results.len]) |slot, score| { try io.write(slot); try io.write(score); }
        },
        11 => {
            const slot = try io.read(u8);
            const generation = try io.read(u64);
            try io.write(@as(u8, @intFromBool(slot < Machines.capacity and machines.used[slot] and machines.generation[slot] == generation)));
        },
        else => return error.Operation,
    }
}
pub fn main() !void {
    var machines: Machines = .{};
    while (true) {
        const operation = io.operation();
        if (operation == -1) return;
        operate(operation, &machines) catch |err| {
            try io.write(@as(u8, 0));
            try io.writeText(@errorName(err));
            try writeRows(&machines);
            continue;
        };
        try io.write(@as(u8, 1));
        try writeRows(&machines);
    }
}
'''


def prepare(repository, output):
    source = repository / 'src/client/machines'
    (output / 'machines').mkdir()
    (output / 'agents').mkdir()
    for name in ['Machines.zig', 'MachineRow.zig', 'MachineResults.zig']:
        shutil.copy2(source / name, output / 'machines' / name)
    collect = function_source((source / 'machine_picker.zig').read_text(), 'collect')
    (output / 'machines/machine_picker.zig').write_text('const core = @import("telar-core");\nconst Machines = @import("Machines.zig");\nconst MachineResults = @import("MachineResults.zig");\n' + collect)
    (output / 'agents/attention.zig').write_text('const data = @import("model");\npub fn group(status: data.Status) data.Status { return status; }\n')
    link = (repository / 'src/model/connection/RuntimeLink.zig').read_text()
    phase = re.search(r'pub const Phase = enum \{[^}]+\};', link).group(0)
    (output / 'model.zig').write_text(model.replace('__PHASE__', phase))
    (output / 'pacing.zig').write_text('const std = @import("std");\npub const clock = struct { pub var now_ns: u64 = 0; pub fn monotonic(_: std.Io) u64 { return now_ns; } };\n')
    shutil.copy2(repository / 'src/core/fuzzy.zig', output / 'fuzzy.zig')
    def limit(filename, name):
        source = (repository / 'src/core' / filename).read_text()
        return int(re.search(r'pub const ' + name + r' = ([0-9]+);', source).group(1))

    capacity = limit('MachineProfiles.zig', 'capacity')
    label_bytes = limit('MachineProfile.zig', 'max_label_bytes')
    color_bytes = limit('MachineProfile.zig', 'max_color_bytes')
    destination_bytes = limit('ssh_destination.zig', 'max_bytes')
    program_bytes = limit('remote_telar.zig', 'max_path_bytes')
    (output / 'core.zig').write_text(f'pub const MachineProfiles = struct {{ pub const capacity = {capacity}; }};\n'
                                   f'pub const MachineProfile = struct {{ pub const max_label_bytes = {label_bytes}; pub const max_color_bytes = {color_bytes}; }};\n'
                                   f'pub const ssh_destination = struct {{ pub const max_bytes = {destination_bytes}; }};\n'
                                   f'pub const remote_telar = struct {{ pub const max_path_bytes = {program_bytes}; }};\n'
                                   'pub const MachineId = enum(u64) { invalid = 0, _ };\n'
                                   'pub const score = @import("fuzzy.zig").score;\n')
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', '--dep', 'model', '--dep', 'pacing',
               '-Mroot=' + str(output / 'probe.zig'), '-Mtelar-core=' + str(output / 'core.zig'),
               '-Mmodel=' + str(output / 'model.zig'), '-Mpacing=' + str(output / 'pacing.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def fields(identity=0, label='', destination='', color='', enabled=True, program=''):
    return struct.pack('<Q', identity) + text(label) + text(destination) + text(color) + bytes([enabled]) + text(program)


def fixtures():
    rng = random.Random(0x4d4143485441424c)
    for series in range(40):
        yield 'reset', b'\1'
        yield 'add-local', b'\2' + fields(label='Personal') + b'\0'
        yield 'local-live', b'\5\0\1'
        used = {0}
        active = 0
        live = {slot: slot == 0 for slot in range(17)}
        enabled = {slot: slot == 0 for slot in range(17)}
        destinations = {0: ''}
        generations = {0: 1}
        next_generation = 2
        for index in range(180):
            operation = rng.randrange(10)
            available = [slot for slot in range(1, 17) if slot not in used and slot != active]
            remotes = sorted(used - {0})
            if operation == 0 and available:
                slot = available[0]
                used.add(slot)
                size = rng.choice([0, 1, 31, 32, 33, 254, 255, 256])
                label = rng.choice(['Work', 'Build', 'xbox', 'box', 'é中', 'x' * size])
                destination = rng.choice(['box', 'dev@work', 'host', 'x' * size])
                color = rng.choice(['', 'red', 'y' * size])
                enabled[slot] = rng.choice([False, True])
                program = rng.choice(['', '/telar', '/' + 'p' * size])
                row = fields(identity=rng.randrange(3), label=label, destination=destination, color=color, enabled=enabled[slot], program=program)
                destinations[slot] = destination[:255]
                generations[slot] = next_generation
                next_generation += 1
                yield 'add', b'\2' + row + b'\xff'
            elif operation == 1 and remotes:
                slot = rng.choice(remotes)
                identity = rng.randrange(3)
                label = rng.choice(['Renamed', 'box'])
                destination = rng.choice(['box', 'other'])
                enabled[slot] = rng.choice([False, True])
                if destinations[slot] != destination:
                    generations[slot] = next_generation
                    next_generation += 1
                destinations[slot] = destination
                yield 'update', b'\3' + bytes([slot]) + fields(identity=identity, label=label, destination=destination, enabled=enabled[slot])
            elif operation == 2 and remotes:
                slot = rng.choice(remotes)
                used.remove(slot)
                enabled[slot] = False
                yield 'remove', b'\4' + bytes([slot])
            elif operation == 3:
                slot = rng.choice(sorted(used))
                live[slot] = bool(rng.randrange(2))
                yield 'live', b'\5' + bytes([slot, live[slot]])
            elif operation == 4:
                slot = rng.randrange(17)
                if slot in used and enabled[slot] and live[slot]:
                    active = slot
                yield 'select', b'\6' + bytes([slot])
            elif operation == 5 and remotes:
                slot = rng.choice(remotes)
                enabled[slot] = True
                yield 'pin', b'\7' + bytes([slot])
            elif operation == 6 and remotes:
                yield 'unpin', b'\10' + bytes([rng.choice(remotes)])
            elif operation == 7:
                slot = rng.choice(sorted(used))
                yield 'summarize', b'\11' + struct.pack('<6B3H4Q', slot, rng.randrange(5), rng.randrange(2), rng.randrange(2), rng.randrange(2), rng.randrange(101), rng.randrange(65), rng.randrange(100), rng.randrange(100, 1000), rng.randrange(4), rng.randrange(4), rng.randrange(4), series * 1000 + index)
            elif operation == 8:
                yield 'collect', b'\12' + text(rng.choice(['', 'box', 'WORK', 'x', 'é', 'other', 'missing', 'z' * 300]))
            else:
                slot = rng.randrange(20)
                generation = generations.get(slot, 0) if rng.randrange(2) else rng.randrange(50)
                yield 'contains', b'\13' + struct.pack('<BQ', slot, generation)
        yield 'collect', b'\12' + text('')


def records(data, cases):
    offset = 0

    def skip_text(position):
        length, = struct.unpack_from('<H', data, position)
        return position + 2 + length

    for kind, request in cases:
        start = offset
        if request[0] in [2, 3, 6, 9, 11]:
            offset += 1
        elif kind == 'collect':
            offset += 1 + data[offset] * 5
        assert data[offset] == 1, (kind, offset)
        offset += 1 + 8 + 3
        for slot in range(17):
            offset += 1 + 8 + 8
            for field in range(4):
                offset = skip_text(offset)
            offset += 6 + 2 + 6 + 32
        yield data[start:offset]
    assert offset == len(data), (offset, len(data))


def main():
    parser = argparse.ArgumentParser(description='Compare window machine state and picker ranking with the original Zig implementation')
    parser.add_argument('--build-dir', type=Path, default=Path('services/gui-cpp/out'))
    parser.add_argument('--output', type=Path, default=Path('services/gui-cpp/out-machines-oracle'))
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(value for _, value in cases)
    (output / 'input.bin').write_bytes(payload)
    binaries = dict(original=output / 'original', cpp=options.build_dir.resolve() / 'gui-machines-probe')
    outputs = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary)], input=payload, capture_output=True, check=True)
        (output / (name + '-output.bin')).write_bytes(result.stdout)
        (output / (name + '-run.log')).write_bytes(result.stderr)
        outputs[name] = result.stdout
    mismatches = [dict(index=index, kind=cases[index][0], input=repr(cases[index][1]), original=expected.hex(), cpp=actual.hex())
                  for index, (expected, actual) in enumerate(zip(records(outputs['original'], cases), records(outputs['cpp'], cases))) if expected != actual]
    if mismatches:
        (output / 'mismatches.json').write_text(json.dumps(mismatches, indent=2) + '\n')
        raise AssertionError(f'{len(mismatches)} machine operations differ; evidence retained in {output}')
    original_sources = ['src/client/machines/' + name for name in ['Machines.zig', 'MachineRow.zig', 'MachineResults.zig', 'machine_picker.zig']]
    original_sources += ['src/core/fuzzy.zig', 'src/model/connection/RuntimeLink.zig']
    original_sources += ['src/core/' + name for name in ['MachineProfiles.zig', 'MachineProfile.zig', 'ssh_destination.zig', 'remote_telar.zig']]
    cpp_sources = ['services/gui-cpp/machines/' + name for name in ['machines.hpp', 'machine_row.hpp', 'machine_token.hpp', 'picker.hpp']]
    cpp_sources += ['services/gui-cpp/palette/ranked_matches.hpp', 'services/gui-cpp/tools/machines_probe.cpp', 'services/gui-cpp/tools/check_machines.py']
    report = dict(cases=len(cases), cases_by_kind=dict(Counter(kind for kind, _ in cases)), input_sha256=hashlib.sha256(payload).hexdigest(),
                  output_bytes=len(outputs['cpp']), output_sha256=hashlib.sha256(outputs['cpp']).hexdigest(), reference_command=command,
                  binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
                  source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in original_sources + cpp_sources},
                  scope='Original Machines and MachineRow sources, extracted unchanged machine_picker.collect and original fuzzy scorer. Injected model facts, attention group and monotonic clock. Complete row snapshots after every operation. No window adapter, SSH, native rendering or comparative performance acceptance.')
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['cases', 'cases_by_kind', 'output_bytes', 'output_sha256']}, indent=2))


if __name__ == '__main__':
    main()
