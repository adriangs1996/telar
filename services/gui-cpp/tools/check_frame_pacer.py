import argparse
from collections import Counter
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


reference = r'''
const std = @import("std");
const Pacer = @import("frame");
const Clock = @import("animate").FrameClock;
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
fn readPane() !Pacer.Pane {
    const pane_id = try read(u64);
    const frame_id = try read(u64);
    const generation = try read(u64);
    return .{
        .pane_id = @enumFromInt(pane_id),
        .frame_id = frame_id,
        .attachment_generation = generation,
        .attached = try read(u8) != 0,
    };
}
fn configure(pacer: *Pacer, clock: *Clock) !void {
    pacer.display_interval_ns = try read(u64);
    const capped = try read(u8) != 0;
    const fps = try read(u16);
    const interval = pacer.pace(if (capped) fps else null, clock);
    std.debug.assert(interval == clock.interval_ns);
}
fn observe(pacer: *Pacer, operation: c_int) !void {
    const now_ns = try read(u64);
    const count = try read(u8);
    var storage: [core.max_panes_per_tab]Pacer.Pane = undefined;
    if (count > storage.len) return error.TooManyPanes;
    const panes = storage[0..count];
    for (panes) |*pane| pane.* = try readPane();
    if (operation == 4) pacer.record(panes, now_ns);
    const deadline = pacer.waitUntil(panes, now_ns);
    try write(@as(u8, @intFromBool(deadline != null)));
    try write(deadline orelse 0);
}
pub fn main() !void {
    var pacer: Pacer = .{};
    var clock: Clock = .{};
    while (true) {
        switch (getchar()) {
            -1 => return,
            0 => pacer = .{},
            1 => try configure(&pacer, &clock),
            2 => {
                const now_ns = try read(u64);
                pacer.noteInput(try readPane(), now_ns);
            },
            3 => try observe(&pacer, 3),
            4 => try observe(&pacer, 4),
            else => return error.InvalidOperation,
        }
        try write(pacer.cadence.interval);
    }
}
'''


reference_sources = [
    'src/gui/FramePacer.zig',
    'src/gui/PaneInputGrace.zig',
    'src/model/panes/PaneCommit.zig',
    'src/core/schema/id.zig',
    'src/core/schema/types.zig',
    'lib/pacing/root.zig',
    'lib/pacing/Pacer.zig',
    'lib/pacing/pace.zig',
    'lib/pacing/Record.zig',
    'lib/pacing/PacerStats.zig',
]


def prepare(root, work):
    gui = work / 'gui'
    gui.mkdir()
    for name in ['FramePacer', 'PaneInputGrace']:
        shutil.copy2(root / f'src/gui/{name}.zig', gui / f'{name}.zig')
    shutil.copy2(root / 'src/model/panes/PaneCommit.zig', work / 'PaneCommit.zig')
    shutil.copy2(root / 'src/core/schema/id.zig', work / 'id.zig')
    shutil.copytree(root / 'lib/pacing', work / 'pacing')
    types = (root / 'src/core/schema/types.zig').read_text()
    constants = []
    for name in ['max_panes_per_tab', 'min_frame_interval_ns', 'max_frame_interval_ns']:
        constants.append(re.search(rf'^pub const {name}\b[^;]*;', types, re.M).group(0))
    (work / 'core.zig').write_text('pub const PaneId = @import("id.zig").PaneId;\n' + '\n'.join(constants) + '\n')
    (work / 'model.zig').write_text('pub const PresentationCommit = struct { pub const PaneCommit = @import("PaneCommit.zig"); };\n')
    (work / 'animate.zig').write_text('pub const FrameClock = struct { interval_ns: u64 = 0 };\n')
    (work / 'probe.zig').write_text(reference)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'frame', '--dep', 'animate', '--dep', 'telar-core', f'-Mroot={work / "probe.zig"}',
        '--dep', 'pacing', '--dep', 'animate', '--dep', 'model', '--dep', 'telar-core', f'-Mframe={gui / "FramePacer.zig"}',
        f'-Mpacing={work / "pacing/root.zig"}', f'-Manimate={work / "animate.zig"}',
        '--dep', 'telar-core', f'-Mmodel={work / "model.zig"}',
        f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original"}',
    ]
    (work / 'reference-command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


maximum_time = 2**64 - 1
default_interval = 1_000_000_000 // 60
input_grace = 30_000_000


def pane(identity=1, frame=0, generation=1, attached=True):
    return struct.pack('<QQQB', identity, frame, generation, attached)


def configure(display=default_interval, fps=None):
    return struct.pack('<BQBH', 1, display, fps is not None, fps or 0)


def note(now, candidate):
    return struct.pack('<BQ', 2, now) + candidate


def observe(now, panes=(), record=False):
    return struct.pack('<BQB', 4 if record else 3, now, len(panes)) + b''.join(panes)


def fixtures():
    yield 'initial', b'\0'
    displays = [0, 1, 1_000_000_000 // 240, default_interval, 1_000_000_000 // 30, maximum_time]
    caps = [None, 0, 1, 29, 30, 59, 60, 120, 240, 241, 65535]
    for display, cap in itertools.product(displays, caps):
        yield 'cadence', b'\0'
        yield 'cadence', configure(display, cap)
        for now in [0, 1, default_interval - 1, default_interval, maximum_time - 1, maximum_time]:
            yield 'cadence', observe(now)
            yield 'cadence', observe(now, record=True)
    for started in [0, 100, maximum_time - input_grace, maximum_time - 1]:
        yield 'input-budget', b'\0'
        yield 'input-budget', observe(started, record=True)
        yield 'input-budget', note(started, pane())
        for frame in range(1, 20):
            yield 'input-budget', observe(started, [pane(frame=frame)])
            yield 'input-budget', observe(started, [pane(frame=frame)], record=True)
        for delta in [0, 1, default_interval - 1, default_interval, input_grace - 1, input_grace]:
            now = min(maximum_time, started + delta)
            yield 'input-budget', observe(now, [pane(frame=21)])
    for elapsed in [0, 1, default_interval - 1, default_interval, default_interval + 1, input_grace - 1, input_grace, input_grace + 1]:
        yield 'input-expiry', b'\0'
        yield 'input-expiry', observe(0, record=True)
        yield 'input-expiry', note(0, pane())
        yield 'input-expiry', observe(elapsed, record=True)
        yield 'input-expiry', observe(elapsed, [pane(frame=1)])
        yield 'input-expiry', observe(elapsed, [pane(frame=1)], record=True)
    for attached, generation, frame, when in itertools.product([False, True], [0, 1, 2], [0, 1, 2], [99, 100, 101]):
        yield 'input-identity', b'\0'
        yield 'input-identity', observe(100, record=True)
        yield 'input-identity', note(100, pane(frame=1))
        yield 'input-identity', note(when, pane(frame=frame, generation=generation, attached=attached))
        for candidate in [pane(frame=2), pane(frame=3, generation=generation, attached=attached), pane(identity=2, frame=3), pane(identity=0, frame=3)]:
            yield 'input-identity', observe(101, [candidate])
            yield 'input-identity', observe(101, [candidate], record=True)
    for tied in [False, True]:
        yield 'eviction', b'\0'
        yield 'eviction', observe(1000, record=True)
        for identity in range(1, 81):
            yield 'eviction', note(1000 if tied else 1000 + identity, pane(identity))
        for identity in range(1, 81):
            yield 'eviction', observe(1100, [pane(identity, frame=1)])
    yield 'duplicate-commits', b'\0'
    yield 'duplicate-commits', observe(0, record=True)
    yield 'duplicate-commits', note(0, pane())
    for frame in range(1, 20):
        yield 'duplicate-commits', observe(1, [pane(frame=frame), pane(frame=maximum_time)], record=True)
        yield 'duplicate-commits', observe(1, [pane(frame=frame + 1)])
    generator = random.Random(0xF12A6E)
    now = 0
    for _ in range(30_000):
        choice = generator.randrange(100)
        if choice < 2:
            now = generator.choice([0, 100, maximum_time - input_grace])
            yield 'random', b'\0'
        elif choice < 8:
            yield 'random', configure(generator.choice(displays), generator.choice(caps))
        else:
            now = max(0, min(maximum_time, now + generator.choice([-default_interval, -1, 0, 1, 100, default_interval, input_grace])))
            candidates = [pane(generator.choice([0, 1, 2, 3, 64, 65, maximum_time]), generator.choice([0, 1, 2, 3, 16, maximum_time]), generator.choice([0, 1, 2, maximum_time]), generator.randrange(8) != 0) for _ in range(generator.choice([1, 2, 4, 64]))]
            if choice < 40:
                yield 'random', note(now, candidates[0])
            else:
                panes = candidates if generator.randrange(8) != 0 else []
                yield 'random', observe(now, panes, record=choice < 75)


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
    payload = b''.join(value for _, value in cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    binary = options.build_dir.resolve() / 'gui-frame-pacer-probe'
    actual = run(binary, payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Frame pacing mismatch at output byte {offset}')
    sources = [root / path for path in reference_sources] + [Path(__file__), Path(__file__).with_name('frame_pacer_probe.cpp'), root / 'services/gui-cpp/presentation/frame_pacer.hpp']
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(cases),
        groups=dict(Counter(name for name, _ in cases)),
        input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))},
        reference_command=command,
        scope='Unchanged original GUI FramePacer, PaneInputGrace, PaneCommit, identifiers and pacing library. Only the FrameClock interval and model/core exports have facades. Compares exact intervals and deadlines after stateful resets, caps, inputs and commits. Covers grace exhaustion/expiry, stale identities, attachment reuse, eviction, duplicate commits, empty spans, backwards time and saturating deadlines. Does not establish native delivery, animation integration, visual parity or comparative performance.',
    )
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', result['operations'], 'frame pacing operations:', result['output_sha256'])


if __name__ == '__main__':
    main()
