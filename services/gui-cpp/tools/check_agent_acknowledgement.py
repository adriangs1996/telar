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


model_source = r'''
const data = @import("../model.zig");
const core = @import("telar-core");
const std = @import("std");
pub const Agent = struct { key: data.AgentKey, status: core.AgentStatus };
const Layout = struct {
    pane: u64 = 0,
    pub fn focused(self: @This()) ?u64 { return if (self.pane != 0) self.pane else null; }
};
const Tabs = struct {
    active: bool = false,
    location: [1]u8 = .{1},
    layout: [1]Layout = .{.{}},
    pub fn activeSlot(self: @This()) ?usize { return if (self.active) 0 else null; }
};
const Snapshot = struct {
    agent: ?Agent = null,
    pub fn keyForPane(self: @This(), _: u8, pane_id: u64) ?data.AgentKey {
        const agent = self.agent orelse return null;
        return if (agent.key.pane_id == pane_id) agent.key else null;
    }
    pub fn find(self: *const @This(), key: data.AgentKey) ?*const Agent {
        const agent = if (self.agent) |*value| value else return null;
        return if (std.meta.eql(agent.key, key)) agent else null;
    }
};
tabs: Tabs = .{},
agent_snapshot: Snapshot = .{},
acknowledged_agent: ?data.AgentKey = null,
'''

reference = r'''
const std = @import("std");
const Model = @import("model/state/ClientModel.zig");
const original = @import("model/agents/agent_done.zig");
const core = @import("telar-core");
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
fn sample(model: *Model) !void {
    const present = try read(u8) != 0;
    const pane_id = try read(u64);
    const generation = try read(u64);
    const status: core.AgentStatus = @enumFromInt(try read(u8));
    model.tabs.active = present;
    model.tabs.layout[0].pane = pane_id;
    model.agent_snapshot.agent = if (present) .{ .key = .{ .pane_id = pane_id, .pane_generation = generation }, .status = status } else null;
}
pub fn main() !void {
    var model: Model = .{};
    while (true) {
        switch (getchar()) {
            -1 => return,
            0 => model = .{},
            1 => try sample(&model),
            else => return error.InvalidOperation,
        }
        const key = original.takeAcknowledgement(&model);
        try write(@as(u8, @intFromBool(key != null)));
        try write(if (key) |value| value.pane_id else @as(u64, 0));
        try write(if (key) |value| value.pane_generation else @as(u64, 0));
    }
}
'''


def prepare(root, work):
    model = work / 'model'
    (model / 'agents').mkdir(parents=True)
    (model / 'state').mkdir()
    shutil.copy2(root / 'src/model/agents/agent_done.zig', model / 'agents/agent_done.zig')
    (model / 'state/ClientModel.zig').write_text(model_source)
    (model / 'model.zig').write_text('pub const AgentKey = struct { pane_id: u64, pane_generation: u64 };\n')
    types = (root / 'src/core/schema/types.zig').read_text()
    status = re.search(r'pub const AgentStatus = enum\(u8\) \{.*?\n\};', types, re.S).group(0)
    (work / 'core.zig').write_text(status + '\n')
    (work / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', f'-Mroot={work / "probe.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


def sample(present=True, pane=1, generation=1, status=5):
    return struct.pack('<BBQQB', 1, present, pane, generation, status)


def fixtures():
    yield b'\0'
    for status, pane, generation in itertools.product(range(6), [1, 2, 2**64 - 1], [0, 1, 9, 2**64 - 1]):
        yield b'\0'
        yield sample(status=status, pane=pane, generation=generation)
        yield sample(status=status, pane=pane, generation=generation)
        yield sample(False)
        yield sample(status=status, pane=pane, generation=generation)
        yield sample(status=1, pane=pane, generation=generation)
        yield sample(status=5, pane=pane, generation=generation)
    generator = random.Random(0xACCA6E17)
    for index in range(6000):
        if generator.randrange(20) == 0:
            yield b'\0'
        else:
            yield sample(generator.randrange(5) != 0, generator.choice([1, 2, 3, 2**64 - 1]), generator.choice([0, 1, 2, 9, 2**64 - 1]), generator.randrange(6))


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
    actual = run(options.build_dir.resolve() / 'gui-agent-acknowledgement-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Agent acknowledgement mismatch at output byte {offset}')
    sources = [root / 'src/model/agents/agent_done.zig', root / 'src/core/schema/types.zig', Path(__file__), Path(__file__).with_name('agent_acknowledgement_probe.cpp'), root / 'services/gui-cpp/application/agent_acknowledgement.hpp']
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(cases),
        input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))},
        reference_command=command,
        scope='Unchanged original agent_done.takeAcknowledgement over a focused-candidate model facade. Compares the one-shot decision and exact pane/generation after every operation, including no focus, all statuses, pane reuse, resets and candidate changes. Tab/location lookup and transactional snapshot integration are covered separately by session tests; native delivery and full GUI parity are outside this oracle.',
    )
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', result['operations'], 'agent acknowledgement operations:', result['output_sha256'])


if __name__ == '__main__':
    main()
