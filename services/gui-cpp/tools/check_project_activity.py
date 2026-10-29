import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import struct
import subprocess

from check_activity_order import pack_text, prepare_workspace_reference
from check_task_labels import function_source


reference = r'''
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const WorkspaceRow = @This();
const Projection = struct {
    workspaces: *const data.WorkspaceListSnapshot,
    agents: @FieldType(data.ClientModel, "agent_snapshot"),
    active: ?core.WorkspaceId,
};
const client = struct {
    pub const Projection = @import("root").Projection;
    pub const agent_attention = @import("agent_attention");
};
const cellgrid = struct { pub const Color = data.Color; };
const workspace_identity = struct {
    fn activeId(projection: *const Projection) ?core.WorkspaceId { return projection.active; }
};
const attention = struct {
    __NEEDS_INPUT__
    __STATUS_COLOR__
};
const Context = struct { projection: *const Projection };
const TextFit = struct { pub const max_bytes = 256; };
const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 10000, height: f32 = 20 };
const Label = struct { text: []const u8, color: data.Color, face: enum { sans }, size: enum { small } };
const Canvas = struct {
    theme: struct { palette: data.Palette = .{} } = .{},
    chrome: struct { fn px(_: @This(), value: f32) f32 { return value; } } = .{},
    label: [8]u8 = undefined,
    length: usize = 0,
    color: data.Color = .overlay1,
    fn measure(_: *@This(), label: Label) !f32 { return @floatFromInt(label.text.len); }
    fn textAt(self: *@This(), _: Rect, label: Label) !f32 {
        @memcpy(self.label[0..label.text.len], label.text);
        self.length = label.text.len;
        self.color = label.color;
        return 0;
    }
};
__INACTIVE_INK__
context: *const Context,
index: usize,
__SUMMARY__
__ATTENTION__

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
fn readText(memory: std.mem.Allocator) ![]const u8 {
    const result = try memory.alloc(u8, try read(u16));
    for (result) |*byte| byte.* = try read(u8);
    return result;
}
fn writeText(text: []const u8) !void {
    const length: u16 = @intCast(text.len);
    for (std.mem.asBytes(&length)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
    for (text) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const project: core.WorkspaceId = @enumFromInt(try read(u64));
    const selected = try read(u8) != 0;
    const Input = @typeInfo(@TypeOf(data.WorkspaceListSnapshot.replace)).@"fn".params[1].type.?;
    const entries = try memory.alloc(std.meta.Child(@FieldType(Input, "entries")), try read(u16));
    for (entries) |*entry| {
        entry.* = .{ .workspace = @enumFromInt(try read(u64)), .name = "project", .path = try readText(memory), .tab_count = 0 };
    }
    const tasks = try memory.alloc(std.meta.Child(@FieldType(Input, "worktrees")), try read(u16));
    for (tasks) |*task| {
        const identity: core.WorktreeId = @enumFromInt(try read(u64));
        const source: core.WorkspaceId = @enumFromInt(try read(u64));
        const workspace = try read(u64);
        task.* = .{ .worktree = identity, .source = source, .workspace = if (workspace == 0) null else @enumFromInt(workspace), .state = @enumFromInt(try read(u8)), .path = "/task", .branch = "worktree-task" };
    }
    var workspaces: data.WorkspaceListSnapshot = .{};
    _ = try workspaces.replace(.{ .revision = 1, .entries = entries, .worktrees = tasks });
    const agents = try memory.alloc(data.Agent, try read(u16));
    for (agents) |*agent| {
        const pane: core.PaneId = @enumFromInt(try read(u64));
        const generation = try read(u64);
        const kind = try read(u8);
        const workspace = try read(u64);
        agent.* = .{
            .key = .{ .pane_id = pane, .pane_generation = generation },
            .location = .{ .workspace = if (kind == 0) .{ .workspace = @enumFromInt(workspace) } else .{ .worktree = @enumFromInt(workspace) } },
            .status = @enumFromInt(try read(u8)), .status_age_s = try read(u32), .work_tree = @enumFromInt(try read(u64)),
        };
    }
    const projection: Projection = .{ .workspaces = &workspaces, .agents = .{ .entries = agents }, .active = if (selected) project else null };
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const summary = worktreeSummary(&projection, project, &buffer);
    if (putchar(@intFromBool(summary != null)) < 0) return error.WriteFailed;
    try writeText(summary orelse "");
    var canvas: Canvas = .{};
    if (workspaces.indexOf(project)) |index| {
        const context: Context = .{ .projection = &projection };
        const row: WorkspaceRow = .{ .context = &context, .index = index };
        _ = try row.drawAttention(&canvas, .{});
    }
    try writeText(canvas.label[0..canvas.length]);
    try writeText(@tagName(canvas.color));
}
pub fn main() !void {
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        if (operation != 0) return error.UnknownOperation;
        try run();
    }
}
'''

palette = r'''
pub const Color = enum {
    text, subtext0, overlay1, teal, green, yellow, red, inactive,
    pub fn rgb(_: anytype) @This() { return .inactive; }
};
pub const Palette = struct {
    text: Color = .text, subtext0: Color = .subtext0, overlay1: Color = .overlay1,
    teal: Color = .teal, green: Color = .green, yellow: Color = .yellow, red: Color = .red,
};
'''


def prepare(root, work):
    prepare_workspace_reference(root, work)
    model = work / 'model.zig'
    model.write_text(model.read_text() + palette)
    source = (root / 'src/gui/widgets/WorkspaceRow.zig').read_text()
    attention = (root / 'src/gui/widgets/attention.zig').read_text()
    replacements = {
        '__NEEDS_INPUT__': function_source(attention, 'needsInput'),
        '__STATUS_COLOR__': function_source(attention, 'statusColor'),
        '__INACTIVE_INK__': re.search(r'^const inactive_ink[^\n]+', source, re.MULTILINE).group(0),
        '__SUMMARY__': function_source(source, 'worktreeSummary'),
        '__ATTENTION__': function_source(source, 'drawAttention'),
    }
    probe = reference
    for marker, value in replacements.items():
        probe = probe.replace(marker, value)
    (work / 'probe.zig').write_text(probe)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'model', '--dep', 'telar-core', '--dep', 'agent_attention', f'-Mroot={work / "probe.zig"}',
        '--dep', 'telar-core', '--dep', 'workspace', f'-Mmodel={work / "model.zig"}',
        '--dep', 'telar-core', f'-Mworkspace={work / "workspace.zig"}',
        '--dep', 'telar-core', '--dep', 'model', f'-Magent_attention={root / "src/client/agents/attention.zig"}',
        f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original-project"}',
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    (work / 'reference-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    return command


def case(name, **fields):
    item = dict(name=name, entries=[(1, "/project")], tasks=[], agents=[], project=1, selected=True)
    item.update(fields)
    return item


def agent(pane=1, **fields):
    report = dict(pane=pane, generation=1, kind=0, workspace=2, status=1, age=0, task=0)
    report.update(fields)
    return report


def fixtures():
    yield case("empty", entries=[])
    yield case("no-worktrees")
    for length in [1, 200, *range(230, 258), 4096]:
        for selected in [False, True]:
            yield case(
                f"path-boundary-{length}-{selected}",
                entries=[(1, "/" * length)],
                tasks=[(1, 1, 0, 0)],
                selected=selected,
            )
    for status in range(6):
        for kind in [0, 1]:
            yield case(
                f"status-{status}-location-{kind}",
                entries=[(1, "/project"), (2, "/task")],
                tasks=[(1, 1, 2, 0)],
                agents=[agent(status=status, kind=kind)],
            )
    for selected in [False, True]:
        for newest in [0, 1]:
            for reverse in [False, True]:
                reports = [
                    agent(pane=2, status=2, age=newest),
                    agent(pane=1, status=4, age=1 - newest),
                ]
                yield case(
                    f"attention-priority-{selected}-{newest}-{reverse}",
                    entries=[(1, "/project"), (2, "/task")],
                    tasks=[(1, 1, 2, 0)],
                    agents=reports[::-1] if reverse else reports,
                    selected=selected,
                )
    yield case(
        "explicit-handle-with-project-location",
        tasks=[(1, 1, 0, 0)],
        agents=[agent(workspace=1, task=1)],
    )
    yield case(
        "handle-cannot-change-project",
        entries=[(1, "/one"), (2, "/two"), (3, "/task")],
        tasks=[(1, 2, 3, 0)],
        agents=[agent(workspace=3, task=1)],
        project=1,
    )
    yield case(
        "maximum-waiting",
        agents=[
            agent(pane=index + 1, workspace=1, status=2 if index % 2 else 4, age=index)
            for index in range(64)
        ],
    )
    yield case(
        "maximum-worktrees",
        tasks=[(index + 1, 1, 0, index % 3) for index in range(64)],
    )
    yield case(
        "nested-workspace-selection",
        entries=[(1, "/one"), (2, "/two")],
        tasks=[(1, 2, 1, 0)],
        agents=[agent(workspace=1, status=2)],
    )
    yield case(
        "path-pool-drop",
        entries=[(index + 1, "/" * 4096) for index in range(64)],
        tasks=[(1, 64, 0, 0)],
        agents=[agent(workspace=64, status=2)],
        project=64,
    )
    generator = random.Random(0x7E1A)
    for index in range(2500):
        entries = [
            (number + 1, generator.choice(["/project", "/界/λ", "/" * 238, "/" * 256, "/" * 4096]))
            for number in range(generator.randrange(1, 20))
        ]
        identities = [identity for identity, _ in entries]
        tasks = [
            (number + 1, generator.choice(identities + [999]), generator.choice([0, *identities]), generator.randrange(2))
            for number in range(generator.randrange(0, 30))
        ]
        reports = [
            agent(
                pane=number + 1,
                workspace=generator.choice(identities + [999]),
                status=generator.randrange(6),
                age=generator.choice([0, 1, 5, 59, 2**32 - 1]),
                generation=generator.randrange(1, 5),
                kind=generator.randrange(2),
                task=generator.choice([0, 999] + [task[0] for task in tasks]),
            )
            for number in range(generator.randrange(65))
        ]
        generator.shuffle(entries)
        generator.shuffle(reports)
        yield case(
            f"random-{index}",
            entries=entries,
            tasks=tasks,
            agents=reports,
            project=generator.choice(identities + [999]),
            selected=bool(generator.randrange(2)),
        )


def encode(item):
    payload = bytearray(struct.pack("<BQB", 0, item["project"], item["selected"]))
    payload += struct.pack("<H", len(item["entries"]))
    for identity, path in item["entries"]:
        payload += struct.pack("<Q", identity) + pack_text(path)
    payload += struct.pack("<H", len(item["tasks"]))
    for task in item["tasks"]:
        payload += struct.pack("<QQQB", *task)
    payload += struct.pack("<H", len(item["agents"]))
    for report in item["agents"]:
        payload += struct.pack(
            "<QQBQBIQ",
            report["pane"], report["generation"], report["kind"], report["workspace"],
            report["status"], report["age"], report["task"],
        )
    return payload


def run_probe(binary, payload, work, name):
    result = subprocess.run([binary], input=payload, capture_output=True, timeout=180)
    (work / (name + ".bin")).write_bytes(result.stdout)
    (work / (name + "-stderr.log")).write_bytes(result.stderr)
    result.check_returncode()
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description="Compare original project worktree summaries and attention labels/colors")
    parser.add_argument("--build-dir", type=Path, default=Path(__file__).resolve().parents[1] / "out")
    parser.add_argument("--output-dir", type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command = prepare(root, work)
    cases = list(fixtures())
    (work / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
    payload = b"".join(encode(item) for item in cases)
    (work / "input.bin").write_bytes(payload)
    expected = run_probe(work / "original-project", payload, work, "original")
    actual = run_probe(options.build_dir.resolve() / "gui-project-activity-probe", payload, work, "cpp")
    if expected != actual:
        offset = next((offset for offset, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f"Project output mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}")
    files = [
        "src/gui/widgets/WorkspaceRow.zig", "src/gui/widgets/attention.zig",
        "src/client/agents/attention.zig", "src/model/workspace/WorkspaceListSnapshot.zig",
        "src/model/workspace/WorktreeRow.zig", "src/model/workspace/Entry.zig",
        "src/model/workspace/workspace_list.zig", "services/gui-cpp/presentation/project_activity.hpp",
        "services/gui-cpp/text/label_text.hpp", "services/gui-cpp/tools/project_activity_probe.cpp",
        "services/gui-cpp/tools/check_project_activity.py", "services/gui-cpp/tools/check_activity_order.py",
    ]
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        cases=len(cases), input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files},
        reference_command=command,
        scope="Unchanged original worktreeSummary and drawAttention functions execute over the actual original workspace replica and shared attention comparator. Canvas records text and palette roles; its synthetic measurement is not compared and does not establish pixel geometry. Covers counts, filtering, ordering, exact bounded formatting, path-pool loss and inactive ink selection for admitted wire records. Native rendering and whole-GUI performance remain outside this oracle.",
    )
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Matched", len(cases), "project cases:", result["output_sha256"])


if __name__ == "__main__":
    main()
