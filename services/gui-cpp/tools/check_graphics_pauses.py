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

from check_notification_center import function_source, run


model_source = r'''
pub const GraphicsPauses = @import("GraphicsPauses.zig");
const core = @import("telar-core");
pub const Outbox = struct {
    requests: [2 * core.max_panes_per_tab]u64 = undefined,
    count: u32 = 0,
    pub fn push(self: *@This(), message: anytype) !void {
        self.requests[self.count] = message.request_graphics_snapshot.pane_id;
        self.count += 1;
    }
};
const Panes = struct {
    closed: u64 = 0,
    pub fn findConst(self: *const @This(), pane_id: u64) ?*const u64 {
        return if (pane_id == self.closed) null else &self.closed;
    }
};
pub const ClientModel = struct {
    graphics_pauses: GraphicsPauses = .{},
    panes: Panes = .{},
    to_runtime: Outbox = .{},
    pane_graphics_revision: u64 = 0,
};
'''

policy_source = r'''
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const Client = @import("Client.zig");
const pacing = @import("pacing");
const runtime_link = @import("runtime_link");
__CONSTANTS__
fn countReach(_: *Client, _: core.LimitReach, _: u32) struct { slot: usize } { return .{ .slot = 0 }; }
fn showPause(client: *Client, _: usize, pane_id: core.PaneId) void {
    client.notices[client.notice_count] = pane_id;
    client.notice_count += 1;
}
fn scheduleResume(_: *Client) !void {}
pub fn pause(client: *Client, pane_id: core.PaneId) !void { try pauseGraphics(client, .{}, pane_id); }
__FUNCTIONS__
'''

probe_source = r'''
const std = @import("std");
const Client = @import("Client.zig");
const policy = @import("policy.zig");
const closed = @import("closed.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn state(client: *const Client) !void {
    try write(client.model.to_runtime.count);
    for (client.model.to_runtime.requests[0..client.model.to_runtime.count]) |pane_id| { try write(pane_id); }
    try write(client.notice_count);
    for (client.notices[0..client.notice_count]) |pane_id| { try write(pane_id); }
    const pauses = &client.model.graphics_pauses;
    const deadline = pauses.nextDue();
    try write(@as(u8, @intFromBool(deadline != null)));
    try write(deadline orelse 0);
    try write(@as(u32, @intCast(pauses.count)));
    for (0..pauses.count) |slot| {
        try write(pauses.pane_id[slot]);
        try write(pauses.resyncs[slot]);
        try write(pauses.since_ns[slot]);
        try write(pauses.due_ns[slot]);
        try write(pauses.backoff[slot]);
        try write(@as(u8, @intFromBool(pauses.waiting[slot])));
        try write(@as(u8, @intFromBool(pauses.snapshot_begun[slot])));
        try write(@as(u8, @intFromBool(pauses.resumed_ns[slot] != null)));
        try write(pauses.resumed_ns[slot] orelse 0);
    }
}
pub fn main() !void {
    var client: Client = .{};
    while (true) {
        const operation = getchar(); if (operation < 0) break;
        client.model.to_runtime.count = 0;
        client.notice_count = 0;
        switch (operation) {
            0 => client = .{},
            1 => { const pane = try read(u64); client.io = try read(u64); try policy.pause(&client, pane); },
            2 => { client.io = try read(u64); try policy.resumeGraphics(&client); },
            3 => { const pane = try read(u64); client.io = try read(u64); try policy.resumeFocused(&client, pane); },
            4 => {
                const pane = try read(u64);
                const phase = try read(u8);
                client.io = try read(u64);
                try policy.receiveGraphicsSnapshot(&client, .{ .pane_id = pane, .phase = @enumFromInt(phase) });
            },
            5 => { client.model.panes.closed = try read(u64); closed.forgetClosedPanes(&client.model); },
            else => return error.UnknownOperation,
        }
        try state(&client);
    }
}
'''


def prepare(root, work):
    source = (root / 'src/client/notifications/limit_reached.zig').read_text()
    types = (root / 'src/core/schema/types.zig').read_text()
    capacity = re.search(r'pub const max_panes_per_tab = .*?;', types).group()
    (work / 'core.zig').write_text(capacity + '\npub const PaneId = u64;\npub const LimitReach = struct {};\npub const Snapshot = struct { pane_id: u64, phase: enum {begin,end} };\n')
    shutil.copy2(root / 'src/model/connection/GraphicsPauses.zig', work / 'GraphicsPauses.zig')
    shutil.copy2(root / 'src/model/connection/limit_reached.zig', work / 'closed.zig')
    (work / 'closed.zig').write_text((work / 'closed.zig').read_text().replace('@import("../state/ClientModel.zig")', '@import("model").ClientModel'))
    (work / 'model.zig').write_text(model_source)
    (work / 'Client.zig').write_text('model: @import("model").ClientModel = .{}, io:u64 = 0, notices:[128]u64=undefined, notice_count:u32=0,\n')
    healthy = re.search(r'pub const healthy_after_ns = .*?;', (root / 'src/client/connection/runtime_link.zig').read_text()).group()
    (work / 'runtime_link.zig').write_text('const std=@import("std");\n' + healthy + '\npub fn lose(_: anytype, _: anyerror) !void {}\n')
    (work / 'pacing.zig').write_text('pub const clock=struct {pub fn monotonic(now:u64) u64{return now;}};\n')
    names = ['pauseGraphics', 'startPause', 'wait', 'pauseWindowNs', 'resumeRow', 'resumeGraphics', 'resumeFocused', 'receiveGraphicsSnapshot', 'askGraphics']
    functions = '\n\n'.join(function_source(source, name) for name in names)
    constants = '\n'.join(re.search(r'const ' + name + r' = .*?;', source).group() for name in ['max_limit_resyncs', 'max_pause_doublings'])
    (work / 'policy.zig').write_text(policy_source.replace('__FUNCTIONS__', functions).replace('__CONSTANTS__', constants))
    (work / 'probe.zig').write_text(probe_source)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'model', '--dep', 'telar-core', '--dep', 'pacing', '--dep', 'runtime_link', f'-Mroot={work / "probe.zig"}', '--dep', 'telar-core', f'-Mmodel={work / "model.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-Mpacing={work / "pacing.zig"}', f'-Mruntime_link={work / "runtime_link.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


def records():
    window = 60_000_000_000
    maximum = 2**64 - 1
    pause = lambda pane, now: struct.pack('<BQQ', 1, pane, now)
    due = lambda now: struct.pack('<BQ', 2, now)
    focus = lambda pane, now: struct.pack('<BQQ', 3, pane, now)
    snapshot = lambda pane, phase, now: struct.pack('<BQBQ', 4, pane, phase, now)
    for start in [0, 1, window - 1, maximum - window, maximum - 1, maximum]:
        yield b'\0'
        for _ in range(5):
            yield pause(1, start)
        for now in [start, min(maximum, start + window - 1), min(maximum, start + window)]:
            yield focus(1, now)
            yield due(now)
        yield snapshot(1, 0, start)
        yield pause(1, start)
        yield snapshot(1, 1, start)
        yield snapshot(1, 0, start)
        yield snapshot(1, 1, start)
        yield pause(1, min(maximum, start + window - 1))
        yield snapshot(1, 0, start)
        yield snapshot(1, 1, start)
        yield pause(1, min(maximum, start + window))
    yield b'\0'
    now = 0
    for _ in range(4):
        yield pause(1, now)
    for backoff in range(280):
        now += window << min(backoff, 4)
        yield due(now)
        for _ in range(3):
            yield pause(1, now)
    yield b'\0'
    for pane in range(1, 65):
        for _ in range(4):
            yield pause(pane, pane)
    yield snapshot(33, 0, window)
    yield snapshot(33, 1, window)
    yield pause(65, window)
    yield pause(66, window)
    yield struct.pack('<BQ', 5, 1)
    yield pause(1, window)
    yield due(maximum)
    rng = random.Random(0x504155534553)
    for scenario in range(20):
        yield b'\0'
        now = rng.choice([0, maximum - 10 * window])
        for _ in range(600):
            pane = rng.randrange(1, 90)
            now = min(maximum, now + rng.choice([0, 1, window - 1, window, 16 * window]))
            operation = rng.randrange(8)
            if operation < 4:
                yield pause(pane, now)
            elif operation == 4:
                yield due(now)
            elif operation == 5:
                yield focus(pane, now)
            elif operation == 6:
                yield snapshot(pane, rng.randrange(2), now)
            else:
                yield struct.pack('<BQ', 5, pane)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command = prepare(root, work)
    cases = list(records())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-graphics-pauses-probe', payload, work, 'cpp')
    if actual != expected:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Graphics pause mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    paths = ['src/model/connection/GraphicsPauses.zig', 'src/model/connection/limit_reached.zig', 'src/client/notifications/limit_reached.zig', 'src/client/connection/runtime_link.zig', 'services/gui-cpp/graphics/pauses.hpp', 'services/gui-cpp/tools/graphics_pauses_probe.cpp', 'services/gui-cpp/tools/check_graphics_pauses.py']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in paths}, generated_sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.glob('*.zig'))}, reference_command=command, scope='Unchanged GraphicsPauses table and original pause/retry/focus/snapshot function bodies. Notification, scheduler and outbox facades record ordered pane effects and derive the next deadline. Counts, row retention/pruning, saturated retry/backoff, snapshot completion, healthy restart and eviction are byte-exact. Does not establish real transport failure, Qt scheduling, ingress admission, notice wording or pixels.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Matched {len(cases)} original graphics pause operations: {result["output_sha256"]}')


if __name__ == '__main__':
    main()
