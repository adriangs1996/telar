import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_notification_center import run


reference = r'''
const std = @import("std");
const Reports = @import("LimitReaches.zig");
const Reach = @import("LimitReach.zig");
const policy = @import("limit_reached.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn readText() ![]const u8 {
    const bytes = try std.heap.page_allocator.alloc(u8, try read(u16));
    for (bytes) |*byte| { byte.* = try read(u8); }
    return bytes;
}
fn writeText(bytes: []const u8) !void {
    try write(@as(u16, @intCast(bytes.len)));
    for (bytes) |byte| { try write(byte); }
}
fn optional(value: ?i64) !void { try write(@as(u8, @intFromBool(value != null))); try write(value orelse 0); }
fn state(reports: *const Reports) !void {
    try write(@as(u32, @intCast(reports.count)));
    try write(reports.evicted);
    for (0..reports.count) |slot| {
        const reach = reports.reachAt(slot);
        try writeText(reach.limit.name);
        try writeText(reach.limit.noun);
        try writeText(reach.route);
        try write(reach.limit.value);
        try write(@as(u8, @intFromBool(reach.requested != null)));
        try write(reach.requested orelse 0);
        try write(reports.hits[slot]);
        try write(reports.unreported[slot]);
        try write(reports.last_ms[slot]);
        try optional(reports.shown_ms[slot]);
        try optional(reports.reported_ms[slot]);
        var buffer: [Reach.max_description_bytes]u8 = undefined;
        try writeText(reach.describe(&buffer, reports.hits[slot]));
    }
}
pub fn main() !void {
    var reports: Reports = .{};
    while (true) {
        const operation = getchar(); if (operation < 0) return;
        var slot: u32 = 0;
        var show = false;
        var hits: ?u32 = null;
        switch (operation) {
            0 => reports = .{},
            1 => {
                const name = try readText(); defer std.heap.page_allocator.free(name);
                const noun = try readText(); defer std.heap.page_allocator.free(noun);
                const route = try readText(); defer std.heap.page_allocator.free(route);
                const value = try read(u64);
                const has_requested = try read(u8) != 0;
                const requested = try read(u64);
                const awake_ms = try read(i64);
                const real_ms = try read(i64);
                const count = try read(u32);
                const result = policy.record(&reports, .{.limit = .{.name = name, .noun = noun, .value = value}, .requested = if (has_requested) requested else null, .route = route}, .{.awake_ms = awake_ms, .real_ms = real_ms}, count);
                slot = @intCast(result.slot);
                show = result.show;
            },
            2 => { slot = try read(u32); hits = policy.takeReport(&reports, slot, try read(i64)); },
            3 => { slot = try read(u32); policy.restoreReport(&reports, slot, try read(u32)); },
            else => return error.InvalidOperation,
        }
        try write(slot);
        try write(@as(u8, @intFromBool(show)));
        try write(@as(u8, @intFromBool(hits != null)));
        try write(hits orelse 0);
        try state(&reports);
    }
}
'''


def text(value):
    encoded = value.encode()
    return struct.pack('<H', len(encoded)) + encoded


def record(name, awake, real, hits=1, noun='', route='runtime_message', value=0, requested=None):
    return b'\1' + text(name) + text(noun) + text(route) + struct.pack('<QBQqqI', value, requested is not None, requested or 0, awake, real, hits)


def cases():
    maximum = 2**64 - 1
    yield b'\0'
    for now in [0, 999, 1000, 1001, 59_999, 60_000, 60_001, 59_000, -1]:
        yield record('GraphicsImageLimitExceeded', now, now)
        yield struct.pack('<BIq', 2, 0, now)
        yield struct.pack('<BII', 3, 0, 2**32 - 1)
    for requested in [None, 0, maximum]:
        yield record('N' * 80, 0, 0, 2**32 - 1, noun='b' * 40, route='r' * 40, value=maximum, requested=requested)
    yield b'\0'
    for index in range(140):
        yield record(f'limit_{index}', index, -index)
    rng = random.Random(0x11A17)
    for _ in range(8):
        yield b'\0'
        seen_names = set()
        now = 0
        for _ in range(500):
            now += rng.choice([-1000, 0, 1, 999, 1000, 60_000])
            if seen_names and rng.randrange(3) == 0:
                slot = rng.randrange(min(len(seen_names), 128))
                if rng.randrange(2):
                    yield struct.pack('<BIq', 2, slot, now)
                else:
                    yield struct.pack('<BII', 3, slot, rng.choice([0, 1, 2**32 - 1]))
            else:
                identifier = rng.randrange(150)
                yield record(f'limit_{identifier}', now, rng.randrange(-10**12, 10**12), rng.choice([0, 1, 2, 2**32 - 1]), noun=rng.choice(['', 'items', 'bytes']), value=rng.choice([0, 1, maximum]), requested=rng.choice([None, 0, 1, maximum]))
                seen_names.add(identifier)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    names = ['Limit.zig', 'LimitReach.zig', 'LimitReaches.zig', 'GenericSlotIndex.zig', 'RecordedReach.zig', 'ReachTime.zig', 'limit_reached.zig']
    sources = [root / 'src/core' / name for name in names]
    for source in sources:
        shutil.copy2(source, work / source.name)
    (work / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', str(work / 'probe.zig'), '-O', 'ReleaseSafe', '-lc', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    records = list(cases())
    payload = b''.join(records)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-limit-reports-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Limit report mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources += [Path(__file__), root / 'services/gui-cpp/application/limit_reports.hpp', root / 'services/gui-cpp/tools/limit_reports_probe.cpp']
    result = dict(created_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(records), output_sha256=hashlib.sha256(actual).hexdigest(), sources={str(source.relative_to(root)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}, command=command, scope='Unmodified original limit ledger, recording/reporting policy and descriptions. Compares all occupied row fields, truncation, eviction, optional requested retention, paced reports, restoration, saturated counts and descriptions. Excludes Qt, transport scheduling, hash collision exhaustion and signed time subtraction overflow.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Matched {len(records)} original limit report operations: {result["output_sha256"]}')


if __name__ == '__main__':
    main()
