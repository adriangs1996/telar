import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_notification_center import function_source, run


reference = r'''
const std = @import("std");
const labels = @import("history_labels.zig");
const Color = enum { teal, yellow, overlay0, red, subtext0 };
const Status = struct { glyph: []const u8, color: Color };
const Palette = struct { teal: Color = .teal, yellow: Color = .yellow, overlay0: Color = .overlay0, red: Color = .red, subtext0: Color = .subtext0 };
const Entry = struct { status: enum(u8) { completed, interrupted, running }, exit_code: ?i32 };
__STATUS_OF__
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
fn writeText(text: []const u8) !void {
    try write(@as(u16, @intCast(text.len)));
    for (text) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn frame(operation: c_int) !void {
    const value = try read(i64);
    var storage: [32]u8 = undefined;
    switch (operation) {
        0 => try writeText(labels.duration(value, &storage)),
        1 => try writeText(labels.age(value, &storage)),
        2 => try write(labels.localDay(value, try read(i16))),
        3 => try writeText(labels.clock(value, try read(i16), &storage)),
        4 => try writeText(labels.dayLabel(value, try read(i64), &storage)),
        5 => {
            const now = try read(i64);
            const offset = try read(i16);
            try writeText(labels.dateLabel(value, now, offset, &storage));
        },
        6 => {
            const present = try read(u8) != 0;
            const code = try read(i32);
            const status = statusOf(Entry{ .status = @enumFromInt(value), .exit_code = if (present) code else null }, Palette{});
            try writeText(status.glyph);
            try writeText(@tagName(status.color));
        },
        7 => try writeText(labels.age((try read(i64)) -| value, &storage)),
        else => return error.InvalidOperation,
    }
}
pub fn main() !void {
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        try frame(operation);
    }
}
'''


def prepare(repository, output):
    shutil.copyfile(repository / 'src/gui/widgets/overlays/history_labels.zig', output / 'history_labels.zig')
    (output / 'cellgrid.zig').write_text('')
    status = function_source((repository / 'src/gui/widgets/overlays/HistoryRow.zig').read_text(), 'statusOf')
    (output / 'probe.zig').write_text(reference.replace('__STATUS_OF__', status))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'cellgrid',
               f'-Mroot={output / "probe.zig"}', f'-Mcellgrid={output / "cellgrid.zig"}', f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def fixtures():
    minimum = -(1 << 63)
    maximum = (1 << 63) - 1
    times = [minimum, -86400001, -1001, -1000, -999, -1, 0, 1, 999, 1000,
             59999, 60000, 3599999, 3600000, 86399999, 86400000, 1709164800000,
             253402300799999, maximum]
    offsets = [-32768, -840, -330, -1, 0, 1, 345, 840, 32767]
    for operation, value in itertools.product([0, 1], times):
        yield struct.pack('<Bq', operation, value)
    for operation, value, offset in itertools.product([2, 3], times, offsets):
        yield struct.pack('<Bqh', operation, value, offset)
    for day, distance in itertools.product([-100000, -1, 0, 1, 31, 10957, 19782, 2932896, 2932897], [-365, -7, -1, 0, 1, 2, 6, 7, 365]):
        yield struct.pack('<Bqq', 4, day, day + distance)
    for value, now, offset in itertools.product(times, times, offsets):
        yield struct.pack('<Bqqh', 5, value, now, offset)
    for status, code in itertools.product(range(3), [None, -(1 << 31), -1, 0, 1, 127, (1 << 31) - 1]):
        yield struct.pack('<BqBi', 6, status, code is not None, code or 0)
    for value, now in itertools.product(times, times):
        yield struct.pack('<Bqq', 7, value, now)
    generator = random.Random(0x41571)
    for _ in range(12000):
        value = generator.randint(minimum, maximum)
        yield struct.pack('<Bq', generator.choice([0, 1]), value)
        yield struct.pack('<Bqh', generator.choice([2, 3]), value, generator.randint(-32768, 32767))
        now = generator.randint(minimum, maximum)
        yield struct.pack('<Bqqh', 5, value, now, generator.randint(-32768, 32767))
        day = generator.randint(-100000, 3000000)
        yield struct.pack('<Bqq', 4, day, day + generator.randint(-1000, 1000))
        yield struct.pack('<Bqq', 7, value, now)


def main():
    parser = argparse.ArgumentParser(description='Compare history date, age, duration and status labels with original Zig source')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-history-labels-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History label mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_labels_probe.cpp'), repository / 'services/gui-cpp/presentation/history_labels.hpp',
               repository / 'services/gui-cpp/core/calendar_sample.hpp', repository / 'services/gui-cpp/text/bounded_text.hpp',
               repository / 'src/gui/widgets/overlays/history_labels.zig', repository / 'src/gui/widgets/overlays/HistoryRow.zig']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
                  source_sha256={str(path.relative_to(repository)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
                  generated_sha256={str(path.relative_to(output)):hashlib.sha256(path.read_bytes()).hexdigest() for path in output.rglob('*.zig')},
                  reference_command=command,
                  scope='Original history_labels duration, age, localDay, clock, dayLabel and dateLabel run unchanged. Original HistoryRow.statusOf is extracted unchanged with named-color recording. Includes signed timestamp/duration extremes, all offset boundaries, calendar bounds, leap dates, future dates, saturating ages, and every status/optional-exit branch. This validates label bytes and color roles, not native clock acquisition, row layout, fonts, complete history behavior or performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'history label records:', result['output_sha256'])


if __name__ == '__main__':
    main()
