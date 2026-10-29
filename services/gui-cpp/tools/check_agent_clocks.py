import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import struct
import subprocess
import tempfile

from check_agent_presentation import enum_source, sha


zig_probe = r'''
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const Age = @import("age");
const status = @import("status");
const Clock = @import("clock");
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
fn write(value: anytype) !void {
    var copy = value;
    for (std.mem.asBytes(&copy)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn agent() !data.Agent {
    const pane = try read(u64);
    const generation = try read(u64);
    const state = try read(u32);
    const provider = try read(u32);
    const seconds = try read(u32);
    return .{.key=.{.pane_id=pane,.pane_generation=generation},.status=@enumFromInt(state),.provider=@enumFromInt(provider),.age=seconds};
}
fn writeAge(age: Age, now: u64) !void {
    try write(age.age_ns);
    try write(age.sampled_ns);
    try write(age.seconds(now));
}
pub fn main() !void {
    var age: Age = undefined;
    while (true) {
        const operation = getchar();
        if (operation < 0) break;
        switch (operation) {
            0, 1 => {
                const observed = try agent();
                const now = try read(u64);
                if (operation == 0) age = Age.init(&observed, now) else age.observe(&observed, now);
                try writeAge(age, now);
            },
            2 => try writeAge(age, try read(u64)),
            3 => {
                const now = try read(u64);
                const state: core.AgentStatus = @enumFromInt(try read(u32));
                const connected = try read(u32) != 0;
                var clock: Clock = .{};
                clock.begin(now);
                if (connected) switch (state) {
                    .working => { _ = clock.step(120 * std.time.ns_per_ms); },
                    .ready => { _ = clock.step(std.time.ns_per_s); },
                    else => {},
                };
                try write(@as(u8, @intFromBool(clock.deadline_ns != null)));
                try write(clock.deadline_ns orelse @as(u64, 0));
                const frame: u8 = @truncate(now / (120 * std.time.ns_per_ms));
                try write(status.pulse(frame));
            },
            else => return error.UnknownClockOperation,
        }
    }
}
'''


def observation(operation, sample, now):
    return struct.pack('<BQQIIIQ', operation, *sample, now)


def records():
    second = 1_000_000_000
    maximum = 2**64 - 1
    ages = [0, 1, 59, 60, 2**32 - 1]
    for state, provider, age in itertools.product(range(6), range(33), ages):
        sample = [1, 1, state, provider, age]
        yield observation(0, sample, second)
        yield observation(1, sample, second + second // 2)
        yield struct.pack('<BQ', 2, 2 * second)
        sample[4] = 0
        yield observation(1, sample, 3 * second)
        sample[2] = (state + 1) % 6
        yield observation(1, sample, 4 * second)
        sample[3] = (provider + 1) % 33
        yield observation(1, sample, 5 * second)
        sample[1] += 1
        yield observation(1, sample, 6 * second)
        yield struct.pack('<BQ', 2, maximum)
        yield observation(1, sample, maximum)
        yield struct.pack('<BQ', 2, 0)

    interval = 120_000_000
    for frame, offset, state, connected in itertools.product(
        range(513), [-1, 0, 1], range(6), range(2)
    ):
        now = max(0, frame * interval + offset)
        yield struct.pack('<BQII', 3, now, state, connected)
    for now, state, connected in itertools.product(
        [maximum, maximum - 1, maximum - interval, 0], range(6), range(2)
    ):
        yield struct.pack('<BQII', 3, now, state, connected)

    generator = random.Random(932845)
    for _ in range(512):
        sample = [
            generator.randrange(1, 65),
            1,
            generator.randrange(6),
            generator.randrange(33),
            generator.randrange(2**32),
        ]
        now = generator.randrange(maximum)
        yield observation(0, sample, now)
        for _ in range(128):
            now = generator.choice([
                generator.randrange(maximum),
                min(maximum, now + generator.randrange(3 * second)),
                max(0, now - generator.randrange(second)),
            ])
            if generator.randrange(3) == 0:
                yield struct.pack('<BQ', 2, now)
            else:
                field = generator.randrange(len(sample))
                if field < 2:
                    sample[field] = generator.choice([1, 2, 64])
                else:
                    field_limit = {2: 6, 3: 33, 4: 2**32}[field]
                    sample[field] = generator.randrange(field_limit)
                yield observation(1, sample, now)


def prepare(root, work):
    types = (root / 'src/core/schema/types.zig').read_text()
    declarations = [
        enum_source(types, name)
        for name in ['AgentStatus', 'AgentProvider', 'AgentBlockedReason']
    ]
    (work / 'core.zig').write_text('\n'.join(declarations))
    (work / 'model.zig').write_text('''
const core = @import("telar-core");
pub const AgentKey = struct {pane_id:u64,pane_generation:u64};
pub const Agent = struct {
    key: AgentKey,
    status: core.AgentStatus,
    provider: core.AgentProvider,
    age: u32,
    pub fn statusAgeSeconds(self: *const Agent) u32 { return self.age; }
};
pub const Palette = struct {teal:[]const u8="",green:[]const u8="",yellow:[]const u8="",red:[]const u8="",overlay1:[]const u8=""};
''')
    (work / 'cellgrid.zig').write_text('pub const Color = []const u8;\n')
    (work / 'probe.zig').write_text(zig_probe)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'model', '--dep', 'telar-core', '--dep', 'age', '--dep', 'status', '--dep', 'clock', f'-Mroot={work / "probe.zig"}',
        '--dep', 'telar-core', f'-Mmodel={work / "model.zig"}',
        f'-Mtelar-core={work / "core.zig"}',
        '--dep', 'model', '--dep', 'telar-core', f'-Mage={root / "src/gui/widgets/StatusAge.zig"}',
        '--dep', 'cellgrid', '--dep', 'model', '--dep', 'telar-core', f'-Mstatus={root / "src/gui/widgets/status_glyph.zig"}',
        f'-Mcellgrid={work / "cellgrid.zig"}',
        f'-Mclock={root / "lib/animate/FrameClock.zig"}',
        f'-femit-bin={work / "original-clock"}',
    ]
    subprocess.run(command, check=True, capture_output=True)
    return command


def compare(actual, expected, cases):
    offset = 0
    for index, case in enumerate(cases):
        length = 13 if case[0] == 3 else 20
        actual_record = actual[offset:offset + length]
        expected_record = expected[offset:offset + length]
        if actual_record != expected_record:
            raise RuntimeError(
                f'Clock differs at record {index}: input={case.hex()}, '
                f'C++={actual_record.hex()}, Zig={expected_record.hex()}'
            )

        offset += length

    if offset != len(actual) or offset != len(expected):
        raise RuntimeError('Unexpected trailing clock output')


def check(root, build, work):
    reference_command = prepare(root, work)
    cases = list(records())
    payload = b''.join(cases)
    (work / 'requests.bin').write_bytes(payload)
    actual = subprocess.run(
        [str(build / 'gui-agent-clock-probe')],
        input=payload,
        capture_output=True,
        check=True,
    ).stdout
    expected = subprocess.run(
        [str(work / 'original-clock')],
        input=payload,
        capture_output=True,
        check=True,
    ).stdout
    compare(actual, expected, cases)
    (work / 'cpp.bin').write_bytes(actual)
    (work / 'original.bin').write_bytes(expected)
    sources = [
        'src/gui/widgets/StatusAge.zig',
        'src/gui/widgets/status_glyph.zig',
        'lib/animate/FrameClock.zig',
        'src/core/schema/types.zig',
        'services/gui-cpp/presentation/status_age.hpp',
        'services/gui-cpp/presentation/agent_animation.hpp',
        'services/gui-cpp/tools/agent_clock_probe.cpp',
        'services/gui-cpp/tools/probe_io.hpp',
        'services/gui-cpp/tools/check_agent_clocks.py',
    ]
    report = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        records=len(cases),
        output_bytes=len(actual),
        output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={name: sha(root / name) for name in sources},
        reference_command=reference_command,
        scope=(
            'Original StatusAge init/observe/seconds and FrameClock step/pulse semantics. '
            'Type facades replace model storage only; original algorithm files compile unchanged. '
            'Does not establish GUI scheduling, snapshot reception timing, full visual parity or performance.'
        ),
    )
    (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description='Compare client status clocks and pulse scheduling with unchanged original Zig helpers'
    )
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    if options.output_dir:
        options.output_dir.mkdir(parents=True, exist_ok=True)
        check(root, options.build_dir.resolve(), options.output_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix='telar-agent-clock-') as directory:
            check(root, options.build_dir.resolve(), Path(directory))


if __name__ == '__main__':
    main()
