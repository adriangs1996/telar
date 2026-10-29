import argparse
import copy
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile

from check_agent_presentation import enum_source, sha


model_facade = r'''
const std = @import("std");
const core = @import("telar-core");
pub const WorkspaceListSnapshot = @import("workspace").Type;
pub const WorktreeRow = std.meta.Child(@FieldType(WorkspaceListSnapshot, "worktrees"));
pub const AgentKey = struct { pane_id: core.PaneId, pane_generation: u64 };
pub const Agent = struct {
    key: AgentKey,
    session_id: [16]u8 = @splat(0),
    location: core.TabLocation,
    status: core.AgentStatus,
    status_age_s: u32,
    work_tree: core.WorktreeId = .invalid,
};
const Agents = struct {
    entries: []const Agent = &.{},
    pub fn slice(self: *const @This()) []const Agent { return self.entries; }
};
const Layout = struct {
    pane: core.PaneId = .invalid,
    pub fn focused(self: @This()) core.PaneId { return self.pane; }
};
const Tabs = struct {
    layout: [1]Layout = .{.{}},
    active: ?usize = null,
    pub fn activeSlot(self: *const @This()) ?usize { return self.active; }
};
pub const ClientModel = struct {
    workspace_list_snapshot: WorkspaceListSnapshot = .{},
    agent_snapshot: Agents = .{},
    tabs: Tabs = .{},
};
'''


zig_probe = r'''
const std = @import("std");
const core = @import("telar-core");
const activity = @import("activity");
const data = @import("model");
const Source = std.meta.Child(@typeInfo(@TypeOf(activity.order)).@"fn".params[0].type.?);
const Output = std.meta.Child(@typeInfo(@TypeOf(activity.order)).@"fn".params[2].type.?);
const Input = @typeInfo(@TypeOf(data.WorkspaceListSnapshot.replace)).@"fn".params[1].type.?;
const WorkspaceInput = std.meta.Child(@FieldType(Input, "entries"));
const WorktreeInput = std.meta.Child(@FieldType(Input, "worktrees"));
const source_capacity = core.MachineProfiles.capacity + 1;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;

fn read(comptime Value: type) !Value {
    var result: Value = 0;
    for (0..@sizeOf(Value)) |index| {
        const byte = getchar();
        if (byte < 0) return error.TruncatedInput;
        result |= @as(Value, @intCast(byte)) << @intCast(index * 8);
    }
    return result;
}

fn bytes(allocator: std.mem.Allocator) ![]const u8 {
    const result = try allocator.alloc(u8, try read(u16));
    for (result) |*byte| byte.* = try read(u8);
    return result;
}

fn optionalId(comptime Value: type) !?Value {
    const value = try read(u64);
    return if (value == 0) null else @enumFromInt(value);
}

fn reference() !?core.CoordinatorReference {
    if (try read(u8) == 0) return null;
    var result: core.CoordinatorReference = undefined;
    for (&result.session_id) |*byte| byte.* = try read(u8);
    result.pane_id = @enumFromInt(try read(u64));
    result.pane_generation = try read(u64);
    return result;
}

fn workspace(allocator: std.mem.Allocator) !WorkspaceInput {
    const id = try read(u64);
    const name = try bytes(allocator);
    const path = try bytes(allocator);
    const tabs = try read(u16);
    const branch = try bytes(allocator);
    const dirty = try read(u8) != 0;
    return .{ .workspace = @enumFromInt(id), .name = name, .path = path, .tab_count = tabs, .branch = branch, .dirty = dirty };
}

fn worktree(allocator: std.mem.Allocator) !WorktreeInput {
    var result: WorktreeInput = undefined;
    result.worktree = @enumFromInt(try read(u64));
    result.source = @enumFromInt(try read(u64));
    result.workspace = try optionalId(core.WorkspaceId);
    result.created_by = try optionalId(core.PaneId);
    result.coordinator = try reference();
    result.state = @enumFromInt(try read(u8));
    result.path = try bytes(allocator);
    result.branch = try bytes(allocator);
    result.base = try bytes(allocator);
    result.title = try bytes(allocator);
    result.diff_added = try read(u32);
    result.diff_removed = try read(u32);
    result.diff_files = try read(u32);
    result.commits_ahead = try read(u32);
    result.command_label = try bytes(allocator);
    result.command_state = @enumFromInt(try read(u8));
    result.command_exit = @bitCast(try read(u32));
    return result;
}

fn agent() !data.Agent {
    var result: data.Agent = undefined;
    result.key.pane_id = @enumFromInt(try read(u64));
    result.key.pane_generation = try read(u64);
    for (&result.session_id) |*byte| byte.* = try read(u8);
    const kind = try read(u8);
    const id = try read(u64);
    result.location = .{ .workspace = if (kind == 0) .{ .workspace = @enumFromInt(id) } else .{ .worktree = @enumFromInt(id) } };
    result.status = @enumFromInt(try read(u8));
    result.status_age_s = try read(u32);
    result.work_tree = @enumFromInt(try read(u64));
    return result;
}

fn source(allocator: std.mem.Allocator, model: *data.ClientModel, agents: *[core.max_agent_snapshot_entries]data.Agent) !Source {
    const slot = try read(u8);
    const focused = try optionalId(core.PaneId);
    model.tabs.active = if (focused == null) null else 0;
    model.tabs.layout[0].pane = focused orelse .invalid;
    var workspaces: [core.max_workspace_list_entries]WorkspaceInput = undefined;
    const workspace_count = try read(u16);
    for (workspaces[0..workspace_count]) |*entry| entry.* = try workspace(allocator);
    var tasks: [core.max_worktree_entries]WorktreeInput = undefined;
    const task_count = try read(u16);
    for (tasks[0..task_count]) |*entry| entry.* = try worktree(allocator);
    _ = try model.workspace_list_snapshot.replace(.{ .revision = 1, .entries = workspaces[0..workspace_count], .worktrees = tasks[0..task_count] });
    const agent_count = try read(u16);
    for (agents[0..agent_count]) |*entry| entry.* = try agent();
    model.agent_snapshot.entries = agents[0..agent_count];
    return .{ .slot = slot, .label = "host", .connected = true, .model = model };
}

fn write(value: anytype) !void {
    var copy_value = value;
    for (std.mem.asBytes(&copy_value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}

fn text(value: []const u8) !void {
    try write(@as(u16, @intCast(value.len)));
    for (value) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}

fn writeWorktree(row: *const data.WorktreeRow) !void {
    try write(core.raw(row.worktree));
    try write(core.raw(row.source));
    try write(if (row.workspace) |id| core.raw(id) else @as(u64, 0));
    try write(if (row.created_by) |id| core.raw(id) else @as(u64, 0));
    try write(@as(u8, @intFromBool(row.coordinator != null)));
    if (row.coordinator) |value| {
        try write(value.session_id);
        try write(core.raw(value.pane_id));
        try write(value.pane_generation);
    }
    try write(@as(u8, @intCast(@intFromEnum(row.state))));
    try text(row.pathSlice());
    try text(row.branchSlice());
    try text(row.baseSlice());
    try text(row.titleSlice());
    try text(row.commandLabel());
    try text(row.handle());
    try text(row.displayName());
    try write(row.diff_added);
    try write(row.diff_removed);
    try write(row.diff_files);
    try write(row.commits_ahead);
    try write(@as(u8, @intCast(@intFromEnum(row.command_state))));
    try write(row.command_exit);
}

fn writeWorkspaces(snapshot: *const data.WorkspaceListSnapshot) !void {
    try write(@as(u16, @intCast(snapshot.count)));
    try write(@as(u16, @intCast(snapshot.project_count)));
    try write(@as(u16, @intCast(snapshot.dropped)));
    try write(@as(u16, @intCast(snapshot.worktree_count)));
    for (0..snapshot.count) |index| {
        try write(core.raw(snapshot.workspaceAt(index)));
        try text(snapshot.nameAt(index));
        try text(snapshot.pathAt(index));
        try text(snapshot.branchAt(index));
        try write(snapshot.tabCountAt(index));
        try write(@as(u8, @intFromBool(snapshot.entries[index].dirty)));
    }
    for (snapshot.worktrees[0..snapshot.worktree_count]) |*row| try writeWorktree(row);
}

fn run(count: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const active = try read(u8);
    var models: [source_capacity]data.ClientModel = @splat(.{});
    var agents: [source_capacity][core.max_agent_snapshot_entries]data.Agent = undefined;
    var sources: [source_capacity]Source = undefined;
    for (sources[0..count], 0..) |*entry, index| entry.* = try source(arena.allocator(), &models[index], &agents[index]);
    try write(@as(u8, @intCast(count)));
    for (models[0..count]) |*model| try writeWorkspaces(&model.workspace_list_snapshot);
    var output: Output = undefined;
    const entries = activity.order(sources[0..count], active, &output);
    try write(@as(u16, @intCast(entries.len)));
    for (entries) |entry| {
        try write(entry.source);
        try write(if (entry.agent) |index| @as(u16, index) else std.math.maxInt(u16));
        try write(entry.worktree orelse std.math.maxInt(u16));
        try write(if (entry.project) |id| core.raw(id) else @as(u64, 0));
        try write(@as(u8, @intCast(@intFromEnum(entry.card))));
        try write(entry.parent orelse std.math.maxInt(u16));
        try write(entry.depth);
        try write(@as(u8, @intFromBool(entry.coordinator)));
        try write(@as(u8, @intFromBool(entry.first_in_project)));
    }
}

pub fn main() !void {
    while (true) {
        const count = getchar();
        if (count < 0) break;
        try run(@intCast(count));
    }
}
'''


def declaration(source, name):
    match = re.search(rf"pub const {name}\s*=\s*([^;]+);", source)
    if not match:
        raise RuntimeError(f"Missing original constant: {name}")
    return f"pub const {name} = {match.group(1)};"


def prepare_workspace_reference(root, work):
    types = (root / 'src/core/schema/types.zig').read_text()
    core = '\n'.join(enum_source(types, name) for name in ['AgentStatus', 'WorktreeState', 'CommandState'])
    constants = [
        'max_agent_snapshot_entries', 'max_worktree_entries',
        'max_workspace_list_entries', 'max_workspace_name_bytes',
        'max_git_branch_bytes', 'max_cwd_bytes',
        'max_worktree_title_bytes', 'max_worktree_command_label_bytes',
    ]
    core += '\n' + '\n'.join(declaration(types, name) for name in constants)
    profiles = (root / 'src/core/MachineProfiles.zig').read_text()
    core += '\npub const MachineProfiles = struct { ' + declaration(profiles, 'capacity') + ' };\n'
    core += r'''
pub const WorkspaceId = enum(u64) { invalid = 0, _ };
pub const WorktreeId = enum(u64) { invalid = 0, _ };
pub const PaneId = enum(u64) { invalid = 0, _ };
pub const WorkspaceLocation = union(enum) { workspace: WorkspaceId, worktree: WorktreeId };
pub const TabLocation = struct { workspace: WorkspaceLocation, tab_id: u64 = 1 };
pub const CoordinatorReference = struct { session_id: [16]u8 = @splat(0), pane_id: PaneId, pane_generation: u64 };
pub fn raw(value: anytype) u64 { return @intFromEnum(value); }
'''
    link = work / 'src'
    if not link.exists():
        link.symlink_to(root / 'src', target_is_directory=True)
    if link.resolve() != root / 'src':
        raise RuntimeError('Reference source link points to another checkout')
    (work / 'core.zig').write_text(core)
    (work / 'model.zig').write_text(model_facade)
    (work / 'workspace.zig').write_text('pub const Type = @import("src/model/workspace/WorkspaceListSnapshot.zig");\n')


def prepare(root, work):
    prepare_workspace_reference(root, work)
    (work / 'activity.zig').write_text('const original = @import("src/client/agents/machine_activity.zig");\npub const order = original.order;\n')
    (work / 'probe.zig').write_text(zig_probe)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'activity', '--dep', 'model', '--dep', 'telar-core', f'-Mroot={work / "probe.zig"}',
        '--dep', 'telar-core', '--dep', 'model', f'-Mactivity={work / "activity.zig"}',
        '--dep', 'telar-core', '--dep', 'workspace', f'-Mmodel={work / "model.zig"}',
        '--dep', 'telar-core', f'-Mworkspace={work / "workspace.zig"}',
        f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original-activity"}',
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    (work / 'reference-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    return command


def workspace(identity, path='/project', **fields):
    result = dict(id=identity, name=f'workspace-{identity}', path=path, tabs=1, branch='main', dirty=False)
    result.update(fields)
    return result


def task(identity, source=1, workspace_id=0, **fields):
    result = dict(
        id=identity, source=source, workspace=workspace_id, creator=0, reference=None,
        state=0, path='/project/task', branch=f'worktree-task-{identity}', base='main',
        title='', added=0, removed=0, files=0, ahead=0,
        command='', command_state=0, command_exit=0,
    )
    result.update(fields)
    return result


def agent(pane, **fields):
    result = dict(pane=pane, generation=1, session=1, kind=0, workspace=1, status=1, age=0, task=0)
    result.update(fields)
    return result


def source(slot=0, workspaces=None, tasks=None, agents=None, focused=0):
    return dict(slot=slot, focused=focused, workspaces=workspaces or [], tasks=tasks or [], agents=agents or [])


def identity(report):
    return report['session'], report['pane'], report['generation']


def fixtures():
    yield dict(name='empty', active=0, sources=[])
    yield dict(name='empty-machines', active=0, sources=[source(slot=index) for index in range(17)])
    for status in range(6):
        for focused in [0, 2]:
            for attribution in ['creator', 'exact', 'stale', 'self']:
                parent = agent(1, status=(status + 1) % 6)
                child = agent(2, task=10, status=status)
                row = task(10, workspace_id=2, creator=1)
                if attribution != 'creator':
                    row['reference'] = identity(parent if attribution != 'self' else child)
                if attribution == 'stale':
                    row['reference'] = (parent['session'], parent['pane'], parent['generation'] + 1)
                rows = [row, task(11, creator=1, command='test', command_state=2)]
                yield dict(
                    name=f'{attribution}-status-{status}-focused-{focused}', active=0,
                    sources=[source(workspaces=[workspace(2), workspace(1)], tasks=rows, agents=[child, parent], focused=focused)],
                )
    for prefix in ['worktree-', 'worktree/', 'worktree-fix', 'worktree/fix', 'feature/fix', 'worktree-λ']:
        yield dict(name=f'handle-{prefix}', active=0, sources=[source(tasks=[task(1, branch=prefix)])])
    yield dict(
        name='utf8-boundaries-and-raw-path-tail', active=0,
        sources=[source(
            workspaces=[workspace(1, '/' + '界' * 200, name='界' * 85 + 'x', branch='w' * 197 + '界')],
            tasks=[task(1, path='/' + '界' * 200, branch='w' * 197 + '界', title='界' * 32, command='λ' * 24, command_state=2)],
        )],
    )
    paths = [workspace(index + 1, '/' * 4096) for index in range(64)]
    yield dict(name='complete-path-pool-overflow', active=0, sources=[source(workspaces=paths, tasks=[task(1, workspace_id=1)])])
    root = agent(1)
    child = agent(2, session=2, task=10)
    yield dict(
        name='cross-machine-aliases', active=2,
        sources=[
            source(slot=0, workspaces=[workspace(1)], agents=[root]),
            source(slot=1, workspaces=[workspace(1)], agents=[copy.deepcopy(root)]),
            source(slot=2, workspaces=[workspace(1)], tasks=[task(10, reference=identity(root))], agents=[child], focused=2),
        ],
    )
    full_sources = []
    for slot in range(17):
        full_sources.append(source(
            slot=slot, workspaces=[workspace(index + 1) for index in range(64)],
            tasks=[task(index + 1, creator=1, command_state=2) for index in range(64)],
            agents=[agent(index + 1, session=slot + 1, status=index % 6, workspace=index + 1) for index in range(64)],
        ))
    yield dict(name='full-2176-node-forest', active=0, sources=full_sources)
    chain_sources = []
    for slot in range(17):
        chain = source(slot=slot, workspaces=[workspace(1)])
        for index in range(64):
            position = slot * 64 + index
            previous = (position - 1) % (17 * 64)
            reference = (previous // 64 + 1, previous % 64 + 1, 1)
            chain['agents'].append(agent(index + 1, session=slot + 1, task=index + 1))
            chain['tasks'].append(task(index + 1, reference=reference))
        chain_sources.append(chain)
    yield dict(name='1088-node-cycle', active=0, sources=chain_sources)


def random_cases():
    generator = random.Random(793_511)
    for case_index in range(1200):
        sources = []
        for slot in range(generator.randrange(1, 5)):
            projects = [workspace(index + 1, '/' + 'p' * generator.choice([15, 255, 511, 4095])) for index in range(generator.randrange(0, 10))]
            tasks = []
            for index in range(generator.randrange(0, 10)):
                bound_workspace = generator.choice([0, 100 + index])
                if bound_workspace:
                    projects.append(workspace(bound_workspace, '/' + 't' * generator.randrange(1, 256)))
                tasks.append(task(
                    10 + index, source=generator.choice([1, 2, 999]), workspace_id=bound_workspace,
                    creator=generator.randrange(0, 24), state=generator.randrange(3),
                    path='/' + 'w' * generator.choice([15, 255, 256, 1023]),
                    branch=generator.choice(['worktree-fix', 'worktree/fix', 'λ-feature', 'worktree-', 'feature/branch']),
                    title=generator.choice(['', 'A task', 'Revisar λ']),
                    added=generator.choice([0, 12, 2**32 - 1]), removed=generator.randrange(20),
                    files=generator.randrange(4), ahead=generator.randrange(5),
                    command=generator.choice(['', 'test', 'build']), command_state=generator.randrange(3),
                    command_exit=generator.choice([0, 1, -1, -2**31, 2**31 - 1]),
                ))
            reports = []
            for index in range(generator.randrange(0, 24)):
                worktree_id = generator.choice([0, 999] + [row['id'] for row in tasks])
                location = generator.choice([row['id'] for row in projects] + [999])
                reports.append(agent(
                    index + 1, generation=generator.randrange(1, 5), session=generator.randrange(1, 5),
                    kind=generator.randrange(2), workspace=location, task=worktree_id,
                    status=generator.randrange(6), age=generator.choice([0, 1, 59, 60, 2**32 - 1]),
                ))
            generator.shuffle(projects)
            generator.shuffle(reports)
            sources.append(source(slot=slot, workspaces=projects, tasks=tasks, agents=reports, focused=generator.randrange(0, 24)))
        candidates = [report for item in sources for report in item['agents']]
        for item in sources:
            for row in item['tasks']:
                if candidates and generator.randrange(3) != 0:
                    target = identity(generator.choice(candidates))
                    if generator.randrange(4) == 0:
                        target = (target[0], target[1], target[2] + 100)
                    row['reference'] = target
        if sources and generator.randrange(5) == 0:
            alias = copy.deepcopy(generator.choice(sources))
            alias['slot'] = len(sources)
            sources.append(alias)
        yield dict(name=f'random-{case_index}', active=generator.randrange(0, len(sources) + 1), sources=sources)


def pack_text(text):
    value = text.encode('utf-8')
    return struct.pack('<H', len(value)) + value


def encode(case):
    output = bytearray(struct.pack('<BB', len(case['sources']), case['active']))
    for item in case['sources']:
        output += struct.pack('<BQH', item['slot'], item['focused'], len(item['workspaces']))
        for entry in item['workspaces']:
            output += struct.pack('<Q', entry['id']) + pack_text(entry['name']) + pack_text(entry['path'])
            output += struct.pack('<H', entry['tabs']) + pack_text(entry['branch']) + struct.pack('<B', entry['dirty'])
        output += struct.pack('<H', len(item['tasks']))
        for row in item['tasks']:
            output += struct.pack('<QQQQB', row['id'], row['source'], row['workspace'], row['creator'], row['reference'] is not None)
            if row['reference'] is not None:
                session, pane, generation = row['reference']
                output += session.to_bytes(16, 'little') + struct.pack('<QQ', pane, generation)
            output += struct.pack('<B', row['state'])
            for field in ['path', 'branch', 'base', 'title']:
                output += pack_text(row[field])
            output += struct.pack('<IIII', row['added'], row['removed'], row['files'], row['ahead'])
            output += pack_text(row['command']) + struct.pack('<Bi', row['command_state'], row['command_exit'])
        output += struct.pack('<H', len(item['agents']))
        for report in item['agents']:
            output += struct.pack('<QQ', report['pane'], report['generation']) + report['session'].to_bytes(16, 'little')
            output += struct.pack('<BQBIQ', report['kind'], report['workspace'], report['status'], report['age'], report['task'])
    return output


class OutputReader:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, count):
        start = self.offset
        self.offset += count
        if self.offset > len(self.data):
            raise RuntimeError('Truncated activity result')
        return self.data[start:self.offset]

    def integer(self, format):
        return struct.unpack(format, self.take(struct.calcsize(format)))[0]

    def text(self):
        self.take(self.integer('<H'))

    def record(self):
        start = self.offset
        for _ in range(self.integer('<B')):
            entries, _, _, tasks = struct.unpack('<4H', self.take(8))
            for _ in range(entries):
                self.take(8)
                for _ in range(3):
                    self.text()
                self.take(3)
            for _ in range(tasks):
                self.take(32)
                if self.integer('<B'):
                    self.take(32)
                self.take(1)
                for _ in range(7):
                    self.text()
                self.take(21)
        count = self.integer('<H')
        maximum_depth = 0
        for _ in range(count):
            values = struct.unpack('<BHHQBHHBB', self.take(20))
            maximum_depth = max(maximum_depth, values[6])
        return self.data[start:self.offset], count, maximum_depth


def compare(actual, expected, cases):
    actual_reader = OutputReader(actual)
    expected_reader = OutputReader(expected)
    node_count = 0
    maximum_depth = 0
    for index, case in enumerate(cases):
        actual_record, count, depth = actual_reader.record()
        expected_record, _, _ = expected_reader.record()
        if actual_record != expected_record:
            mismatch = next((offset for offset, values in enumerate(zip(actual_record, expected_record)) if values[0] != values[1]), min(len(actual_record), len(expected_record)))
            raise RuntimeError(f'Activity differs in case {index} {case["name"]} at byte {mismatch}: C++={actual_record[mismatch:mismatch + 48].hex()}, Zig={expected_record[mismatch:mismatch + 48].hex()}')
        node_count += count
        maximum_depth = max(maximum_depth, depth)
    if actual_reader.offset != len(actual) or expected_reader.offset != len(expected):
        raise RuntimeError('Trailing activity output')
    return node_count, maximum_depth


def check(root, build, work):
    command = prepare(root, work)
    cases = list(fixtures()) + list(random_cases())
    requests = b''.join(encode(case) for case in cases)
    (work / 'requests.bin').write_bytes(requests)
    (work / 'cases.json').write_text(json.dumps([case['name'] for case in cases], indent=2) + '\n')
    actual = subprocess.run([str(build / 'gui-activity-probe')], input=requests, capture_output=True, check=True).stdout
    expected = subprocess.run([str(work / 'original-activity')], input=requests, capture_output=True, check=True).stdout
    (work / 'cpp.bin').write_bytes(actual)
    (work / 'original.bin').write_bytes(expected)
    nodes, maximum_depth = compare(actual, expected, cases)
    originals = [
        'src/client/agents/machine_activity.zig', 'src/client/agents/fleet_order.zig',
        'src/client/agents/attention.zig', 'src/client/agents/FleetEntry.zig',
        'src/client/agents/FleetCard.zig', 'src/client/agents/MachineActivityEntry.zig',
        'src/client/agents/FleetSources.zig', 'src/client/machines/MachineActivity.zig',
        'src/client/machines/Machines.zig', 'src/core/MachineProfiles.zig',
        'src/core/schema/types.zig', 'src/model/workspace/WorkspaceListSnapshot.zig',
        'src/model/workspace/WorktreeRow.zig', 'src/model/workspace/WorktreeInput.zig',
        'src/model/workspace/Entry.zig', 'src/model/workspace/EntryInput.zig',
        'src/model/workspace/WorkspaceListInput.zig', 'src/model/workspace/workspace_list.zig',
    ]
    implementations = [
        'application/records.hpp', 'application/agent_replica.hpp',
        'application/workspace_replica.hpp', 'presentation/agent_order.hpp',
        'presentation/activity_card.hpp', 'presentation/activity_order.hpp',
        'tools/activity_probe.cpp', 'tools/check_activity_order.py', 'tools/probe_io.hpp', 'tools/probe_text.hpp',
    ]
    sources = originals + ['services/gui-cpp/' + name for name in implementations]
    report = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        cases=len(cases), activity_nodes=nodes, maximum_depth=maximum_depth,
        output_bytes=len(actual), input_sha256=hashlib.sha256(requests).hexdigest(),
        output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={name: sha(root / name) for name in sources},
        facade_sha256={name: sha(work / name) for name in ['probe.zig', 'core.zig', 'model.zig', 'activity.zig', 'workspace.zig']},
        reference_command=command,
        scope='Unmodified original workspace/worktree replica construction, labels, fleet ordering and global machine activity ordering. Model storage, tab focus and protocol handle types use facades. Does not establish card rasterization, native navigation, remote connections or comparative performance.',
    )
    (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description='Compare activity trees and workspace metadata with the original Zig implementation')
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--output-dir', type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = (options.build_dir or root / 'services/gui-cpp/out').resolve()
    if options.output_dir:
        options.output_dir.mkdir(parents=True, exist_ok=True)
        check(root, build, options.output_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='telar-activity-order-') as directory:
            check(root, build, Path(directory))


if __name__ == '__main__':
    main()
