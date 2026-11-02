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
import tempfile

from check_activity_order import pack_text
from check_agent_presentation import enum_source, sha


facades = r'''
const std = @import("std");
const core = @import("telar-core");
const TaskCard = @This();
const Color = enum { text, subtext0, overlay1, teal, yellow, red, surface1 };
const Palette = struct {
    text: Color = .text, subtext0: Color = .subtext0, overlay1: Color = .overlay1,
    teal: Color = .teal, yellow: Color = .yellow, red: Color = .red, surface1: Color = .surface1,
};
const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
const Label = struct { text: []const u8, color: Color, face: enum { sans }, size: enum { small } };
const TextFit = struct { pub const max_bytes = 256; };
const Text = struct {
    bytes: [std.math.maxInt(u16)]u8 = undefined,
    len: u16 = 0,
    color: Color = .text,
    fn assign(self: *@This(), label: Label) void {
        @memcpy(self.bytes[0..label.text.len], label.text);
        self.len = @intCast(label.text.len);
        self.color = label.color;
    }
    fn view(self: *const @This()) []const u8 { return self.bytes[0..self.len]; }
};
const Canvas = struct {
    theme: struct { palette: Palette = .{} } = .{},
    cells: u16 = 0,
    filled: u16 = 0,
    labels: usize = 0,
    first: Text = .{},
    last: Text = .{},
    fn measure(_: *@This(), _: Label) !f32 { return 0; }
    fn textAt(self: *@This(), _: Rect, label: Label) !f32 {
        if (self.labels == 0) self.first.assign(label);
        self.last.assign(label);
        self.labels += 1;
        return 0;
    }
    fn fillRoundedAt(self: *@This(), _: Rect, style: struct { radius: f32, color: Color }) !void {
        self.cells += 1;
        self.filled += @intFromBool(style.color == .teal);
    }
};
const CardGeometry = struct {
    scale: f32 = 1,
    pub const gap: f32 = 6;
    __PIXELS__
};
const WorktreeRow = struct {
    branch: []const u8 = "",
    command_label: []const u8 = "",
    command_state: core.CommandState = .none,
    command_exit: i32 = 0,
    diff_added: u32 = 0, diff_removed: u32 = 0, diff_files: u32 = 0, commits_ahead: u32 = 0,
    fn branchSlice(self: *const @This()) []const u8 { return self.branch; }
    fn commandLabel(self: *const @This()) []const u8 { return self.command_label; }
    __HANDLE__
};
const Agent = struct {
    status: core.AgentStatus = .unknown,
    plan_done: u16 = 0, plan_total: u16 = 0,
    event: []const u8 = "", final: []const u8 = "", step: []const u8 = "",
    fn lastEvent(self: *const @This()) []const u8 { return self.event; }
    fn finalMessage(self: *const @This()) []const u8 { return self.final; }
    fn planStep(self: *const @This()) []const u8 { return self.step; }
    __FINAL_LINE__
};
task: *const WorktreeRow,
agent: *const Agent,
machine_label: []const u8,
geometry: CardGeometry = .{},

fn fitted(canvas: *Canvas, area: Rect, label: Label) !void {
    if (area.width > 0) _ = try canvas.textAt(area, label);
}

__FACTS__
__ACTIVITY__
__PLAN__
__PLAN_LIMIT__

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
fn readText(allocator: std.mem.Allocator) ![]const u8 {
    const result = try allocator.alloc(u8, try read(u16));
    for (result) |*byte| byte.* = try read(u8);
    return result;
}
fn write(value: anytype) !void {
    var copy_value = value;
    for (std.mem.asBytes(&copy_value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn writeText(value: []const u8) !void {
    try write(@as(u16, @intCast(value.len)));
    for (value) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn run(operation: u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var row: WorktreeRow = .{};
    var agent_value: Agent = .{};
    var machine: []const u8 = "";
    switch (operation) {
        0 => {
            machine = try readText(memory);
            row.branch = try readText(memory);
            row.command_label = try readText(memory);
            row.diff_added = try read(u32);
            row.diff_removed = try read(u32);
            row.diff_files = try read(u32);
            row.commits_ahead = try read(u32);
            row.command_state = @enumFromInt(try read(u8));
            row.command_exit = @bitCast(try read(u32));
        },
        1 => {
            agent_value.status = @enumFromInt(try read(u8));
            agent_value.plan_done = try read(u16);
            agent_value.plan_total = try read(u16);
            agent_value.event = try readText(memory);
            agent_value.final = try readText(memory);
            agent_value.step = try readText(memory);
        },
        else => return error.UnknownOperation,
    }
    const card: TaskCard = .{ .task = &row, .agent = &agent_value, .machine_label = machine };
    var canvas: Canvas = .{};
    const area: Rect = .{ .x = 0, .y = 0, .width = 10000, .height = 15 };
    try write(operation);
    if (operation == 0) {
        try card.drawFacts(&canvas, area);
        try writeText(canvas.last.view());
    } else {
        try card.drawActivity(&canvas, area);
        try write(canvas.cells);
        try write(canvas.filled);
        try writeText(if (canvas.cells != 0) canvas.first.view() else "");
        try writeText(canvas.last.view());
        try writeText(@tagName(canvas.last.color));
    }
}
pub fn main() !void {
    while (true) {
        const operation = getchar();
        if (operation < 0) break;
        try run(@intCast(operation));
    }
}
'''


def function_source(source, name):
    match = re.search(rf'^(?:pub )?fn {name}\([^\n]+\)[^\n]*\{{\n.*?^\}}', source, re.MULTILINE | re.DOTALL)
    if not match:
        raise RuntimeError(f'Missing original function: {name}')
    return match.group(0)


def prepare(root, work):
    task_source = (root / 'src/gui/widgets/TaskCard.zig').read_text()
    replacements = {
        '__PIXELS__': function_source((root / 'src/gui/widgets/CardGeometry.zig').read_text(), 'px'),
        '__HANDLE__': function_source((root / 'src/model/workspace/WorktreeRow.zig').read_text(), 'handle'),
        '__FINAL_LINE__': function_source((root / 'src/model/agents/Agent.zig').read_text(), 'finalLine'),
        '__FACTS__': function_source(task_source, 'drawFacts'),
        '__ACTIVITY__': function_source(task_source, 'drawActivity'),
        '__PLAN__': function_source(task_source, 'drawPlanBar'),
        '__PLAN_LIMIT__': re.search(r'^const max_plan_cells = [^;]+;', task_source, re.MULTILINE).group(0),
    }
    probe = facades
    for marker, value in replacements.items():
        probe = probe.replace(marker, value)
    (work / 'probe.zig').write_text(probe)
    types = (root / 'src/core/schema/types.zig').read_text()
    (work / 'core.zig').write_text('\n'.join(enum_source(types, name) for name in ['AgentStatus', 'CommandState']))
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core',
        f'-Mroot={work / "probe.zig"}', f'-Mtelar-core={work / "core.zig"}',
        f'-femit-bin={work / "original-task-labels"}',
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    (work / 'reference-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    return command, {name: hashlib.sha256(value.encode()).hexdigest() for name, value in replacements.items()}


def facts(machine, branch, command, **fields):
    values = dict(added=12, removed=3, files=2, ahead=1, state=2, exit_code=0)
    values.update(fields)
    counts = [values[name] for name in ['added', 'removed', 'files', 'ahead', 'state', 'exit_code']]
    return b'\x00' + pack_text(machine) + pack_text(branch) + pack_text(command) + struct.pack('<IIIIBi', *counts)


def activity(status, done, total, **labels):
    text = b''.join(pack_text(labels[name]) for name in ['event', 'final', 'step'])
    return b'\x01' + struct.pack('<BHH', status, done, total) + text


def requests():
    for machine_length, branch_length, command_length in itertools.product([0, 1, 31, 32, 33, 100, 253, 256, 1024], [1, 8, 199, 200], [0, 1, 48]):
        for state in range(3):
            yield facts('m' * machine_length, 'b' * branch_length, 'c' * command_length, state=state)
    for machine, branch, command in itertools.product(['', 'host', '界' * 10], ['worktree-', 'worktree/', 'worktree-fix', 'worktree/fix', '界' * 66], ['', 'test', 'λ' * 24]):
        yield facts(machine, branch, command, added=2**32 - 1, removed=2**32 - 1, files=2**32 - 1, ahead=2**32 - 1, exit_code=-2**31)
    for status, total, final in itertools.product(range(6), [0, 1, 2, 4, 8, 9, 65535], ['', '\n \t\n Final answer\t\nmore', '\r\nother', '界' * 682]):
        for done in sorted({0, total // 2, total}):
            yield activity(status, done, total, event='Last event', final=final, step='Plan step')
    generator = random.Random(942_711)
    for _ in range(1500):
        if generator.randrange(2):
            yield facts(
                'm' * generator.randrange(0, 300),
                generator.choice(['worktree-', 'worktree/', '']) + 'b' * generator.randrange(1, 192),
                'test', added=generator.randrange(2**32), removed=generator.randrange(2**32),
                files=generator.randrange(0, 30), ahead=generator.randrange(0, 30),
                state=generator.randrange(3), exit_code=generator.randrange(-2**31, 2**31),
            )
        else:
            total = generator.randrange(65536)
            yield activity(generator.randrange(6), generator.randrange(total + 1), total, event='λ event', final='\n\t final\t\nmore', step='step')


def record(data, offset):
    start = offset
    operation = data[offset]
    offset += 1
    text_count = 1
    if operation == 1:
        offset += 4
        text_count = 3
    for _ in range(text_count):
        length = struct.unpack_from('<H', data, offset)[0]
        offset += 2 + length
    if offset > len(data):
        raise RuntimeError('Truncated task label output')
    return data[start:offset], offset


def check(root, build, work):
    command, functions = prepare(root, work)
    cases = list(requests())
    payload = b''.join(cases)
    (work / 'requests.bin').write_bytes(payload)
    outputs = {}
    for name, executable in [('cpp', build / 'gui-task-labels-probe'), ('original', work / 'original-task-labels')]:
        result = subprocess.run([str(executable)], input=payload, capture_output=True)
        (work / f'{name}.bin').write_bytes(result.stdout)
        (work / f'{name}.stderr.log').write_bytes(result.stderr)
        result.check_returncode()
        outputs[name] = result.stdout
    actual_offset = expected_offset = 0
    for index, case in enumerate(cases):
        actual, actual_offset = record(outputs['cpp'], actual_offset)
        expected, expected_offset = record(outputs['original'], expected_offset)
        if actual != expected:
            raise RuntimeError(f'Task label differs at case {index}, operation {case[0]}: C++={actual.hex()}, Zig={expected.hex()}')
    if actual_offset != len(outputs['cpp']) or expected_offset != len(outputs['original']):
        raise RuntimeError('Trailing task label output')
    sources = [
        'src/gui/widgets/TaskCard.zig', 'src/gui/widgets/CardGeometry.zig',
        'src/model/workspace/WorktreeRow.zig', 'src/model/agents/Agent.zig',
        'src/core/schema/types.zig', 'services/gui-cpp/application/records.hpp',
        'services/gui-cpp/presentation/task_card_labels.hpp',
        'services/gui-cpp/tools/task_labels_probe.cpp', 'services/gui-cpp/tools/check_task_labels.py',
        'services/gui-cpp/tools/probe_text.hpp',
    ]
    report = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        cases=len(cases), output_bytes=len(outputs['cpp']),
        input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(outputs['cpp']).hexdigest(),
        source_sha256={name: sha(root / name) for name in sources},
        extracted_function_sha256=functions, reference_command=command,
        scope='Original drawFacts, drawActivity, drawPlanBar, handle, finalLine and px bodies are extracted without edits. Rendering, borrowed model access and font fitting use recording facades. Checks raw fact text, activity text/color, plan cell counts and filled counts. Font fitting, geometry/rasterization, native scheduling and performance are outside this oracle.',
    )
    (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description='Compare task labels and plan counts with original Zig method bodies')
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--output-dir', type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = (options.build_dir or root / 'services/gui-cpp/out').resolve()
    if options.output_dir:
        options.output_dir.mkdir(parents=True, exist_ok=True)
        check(root, build, options.output_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='telar-task-labels-') as directory:
            check(root, build, Path(directory))


if __name__ == '__main__':
    main()
