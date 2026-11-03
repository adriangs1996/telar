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


reference = r'''
const std = @import("std");
const gfx = @import("gfx");
const client = @import("telar-client");
const GpuImages = @import("GpuImages.zig");
const ImageUpload = gfx.ImageUpload;
__CONSTANTS__
const Metadata = struct { retire_pending: bool = false };
const Catalog = struct {
    machine: u8 = 0,
    catalogs: u64 = 0,
    generations: u64 = 0,
    entry: Metadata = .{},
    fn getPtr(self: *Catalog, identity: client.ImageIdentity) ?*Metadata {
        const catalog = @as(u64, self.machine) * 16 + @intFromEnum(identity.pane_id);
        if ((self.catalogs >> @intCast(catalog - 1)) & 1 == 0 or (self.generations >> @intCast(identity.generation % 64)) & 1 == 0) return null;
        return &self.entry;
    }
};
const Store = struct { total_bytes: usize = 0, images: Catalog = .{} };
const Placement = struct { handle: u32 };
const PaneImages = struct {
    gpu: GpuImages = .{},
    frame: u64 = 0,
    revision: u64 = 1,
    now_ns: u64 = 0,
    presented: u64 = 0,
    releases: [ImageUpload.capacity]u32 = undefined,
    release_count: u32 = 0,
    placement: [1]Placement = undefined,
    placement_count: usize = 0,
    fn resolved(self: *const @This()) []const Placement { return self.placement[0..self.placement_count]; }
};
const Wanted = struct { machine: u8, identity: client.ImageIdentity, width: u32, height: u32 };
__FUNCTIONS__
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
const Digest = struct {
    value: u64 = 14695981039346656037,
    fn add(self: *@This(), input: u64) void {
        var value = input;
        for (0..8) |_| { self.value = (self.value ^ (value & 255)) *% 1099511628211; value >>= 8; }
    }
};
const Identity = struct { machine: u8, key: client.ImageIdentity };
fn readIdentity() !Identity {
    const catalog = try read(u64);
    return .{.machine = @intCast((catalog - 1) / 16), .key = .{.pane_id = @enumFromInt((catalog - 1) % 16 + 1), .image_id = try read(u32), .generation = try read(u64)}};
}
const Admission = struct { handle: u32 = 0, upload: u8 = 0, reuse: u8 = 0 };
fn request(images: *PaneImages, uploads: *usize) !Admission {
    const identity = try readIdentity();
    const width = try read(u32); const height = try read(u32);
    var stores: [4]Store = @splat(.{}); stores[0].total_bytes = try read(u64);
    const now_ns = try read(u64);
    if (images.gpu.find(identity.machine, identity.key)) |row| return .{.handle = GpuImages.handleOf(row)};
    if (images.gpu.uploading >= ImageUpload.uploads_in_flight or uploads.* >= ImageUpload.uploads_in_flight or images.gpu.uploadsOf(identity.machine, identity.key) == uploads_per_image) return .{};
    const row = takeRow(images, &stores, .{.machine = identity.machine, .identity = identity.key, .width = width, .height = height}) orelse return .{};
    if (width > ImageUpload.max_side or height > ImageUpload.max_side) return .{.handle = GpuImages.handleOf(row)};
    const reuse = images.gpu.bytes[row] != 0;
    if (!reuse) { images.gpu.bytes[row] = @as(usize, width) * height * rgba_bytes; images.gpu.resident_bytes += images.gpu.bytes[row]; }
    images.gpu.residency[row] = .uploading;
    images.gpu.started_ns[row] = now_ns; images.gpu.used_ns[row] = now_ns;
    images.gpu.uploading += 1; uploads.* += 1;
    return .{.handle = GpuImages.handleOf(row), .upload = 1, .reuse = @intFromBool(reuse)};
}
fn complete(images: *PaneImages) !bool {
    const handle = try read(u32); const result = .{.success = try read(u8) != 0}; const now_ns = try read(u64);
    const row = GpuImages.rowOf(handle) orelse return false;
    if (images.gpu.residency[row] != .uploading) return false;
    const elapsed: ?u64 = ret: {
__COMPLETION__
    };
    _ = elapsed;
    return true;
}
fn digestOf(images: *const PaneImages) Digest {
    var digest: Digest = .{};
    const gpu = &images.gpu;
    for (gpu.rows()) |row| {
        digest.add(row); digest.add(@intFromEnum(gpu.residency[row]));
        digest.add(@as(u64, gpu.machine[row]) * 16 + @intFromEnum(gpu.identity[row].pane_id));
        digest.add(gpu.identity[row].image_id); digest.add(gpu.identity[row].generation);
        digest.add(gpu.width[row]); digest.add(gpu.height[row]); digest.add(gpu.bytes[row]);
        digest.add(gpu.started_ns[row]); digest.add(gpu.used_frame[row]); digest.add(gpu.used_ns[row]); digest.add(@intFromBool(gpu.presented[row]));
    }
    return digest;
}
pub fn main() !void {
    var images: PaneImages = .{}; var uploads: usize = 0; var releases: Digest = .{}; var released: u64 = 0; var query_ns: u64 = 0;
    while (true) {
        const operation = getchar(); if (operation < 0) return;
        var result: Admission = .{};
        switch (operation) {
            0 => { images = .{}; uploads = 0; releases = .{}; released = 0; query_ns = 0; },
            1 => { images.frame += 1; images.now_ns = try read(u64); query_ns = images.now_ns; uploads = 0; trim(&images); },
            2 => { result = try request(&images, &uploads); },
            3 => { result.upload = @intFromBool(try complete(&images)); },
            4, 5 => {
                const handle = try read(u32);
                if (GpuImages.rowOf(handle)) |row| {
                    if (images.gpu.residency[row] != .free) {
                        if (operation == 4) {
                            images.placement[0] = .{.handle = handle}; images.placement_count = 1; markStandIns(&images); images.placement_count = 0;
                        } else { noteDrawn(&images, &.{.{.handle = handle}}); }
                    }
                }
            },
            6 => {
                const catalogs = try read(u64); const generations = try read(u64); var stores: [4]Store = @splat(.{});
                for (&stores, 0..) |*store, machine| { store.images = .{.machine = @intCast(machine), .catalogs = catalogs, .generations = generations}; }
                sweep(&images, &stores);
            },
            7 => { const identity = try readIdentity(); if (images.gpu.findNewestReady(identity.machine, identity.key)) |row| { result.handle = GpuImages.handleOf(row); } },
            8 => { query_ns = try read(u64); },
            else => return error.InvalidOperation,
        }
        for (images.releases[0..images.release_count]) |handle| { releases.add(handle); released += 1; }
        images.release_count = 0;
        try write(result.handle); try write(result.upload); try write(result.reuse);
        try write(images.frame); try write(images.revision); try write(images.presented); try write(@as(u64, images.gpu.resident_bytes));
        try write(@as(u64, images.gpu.uploading)); try write(@as(u64, images.gpu.spares)); try write(@as(u64, images.gpu.count));
        try write(digestOf(&images).value); try write(released); try write(releases.value);
        try write(wakeupAfter(&images, query_ns)); try write(@as(u8, @intFromBool(trimDue(&images, query_ns))));
    }
}
'''


def identity(catalog=1, image=1, generation=1):
    return struct.pack('<QIQ', catalog, image, generation)


def request(catalog=1, image=1, generation=1, size=(2, 2), retained=0, now=0):
    return b'\2' + identity(catalog, image, generation) + struct.pack('<IIQQ', *size, retained, now)


def frame(now):
    return b'\1' + struct.pack('<Q', now)


def complete(handle, success=True, now=0):
    return b'\3' + struct.pack('<IBQ', handle, success, now)


def sweep(catalogs=0, generations=0):
    return b'\6' + struct.pack('<QQ', catalogs, generations)


def fixtures():
    quota = 512 * 1024 * 1024
    all_bits = 2**64 - 1
    yield b'\0'
    yield frame(0)
    for generation in range(1, 5):
        yield request(generation=generation)
    yield complete(2)
    yield complete(1)
    yield b'\7' + identity()
    yield b'\5' + struct.pack('<I', 2)
    yield frame(1)
    yield sweep()
    yield request(image=2, retained=quota, now=1)
    yield complete(1, False, 2)
    yield b'\0'
    yield frame(0)
    for image in range(1, 513):
        yield request(image=image, size=(16385, 1), retained=quota)
    yield request(image=513)
    yield sweep()
    for image in range(1, 9):
        yield frame(image)
        yield request(image=image)
        yield complete(1)
        yield sweep()
    yield frame(2_000_000_008)
    yield frame(5_000_000_008)
    yield b'\0'
    for image in range(1, 9):
        yield frame(image)
        yield request(image=image, now=image)
        yield complete(image, now=image)
    yield frame(9)
    yield sweep()
    for retained in [0, 1, quota // 2, quota - 1, quota, quota + 1]:
        yield b'\0'
        yield frame(0)
        for image in range(1, 5):
            yield request(image=image, size=(8192, 4096), retained=retained)
            yield complete(image)
        yield b'\5' + struct.pack('<I', 1)
        yield frame(1)
        yield request(image=5, size=(8192, 4096), retained=retained)
        yield frame(2)
        yield request(image=5, size=(8192, 4096), retained=retained)
    rng = random.Random(0x6A11E7)
    for _ in range(24):
        yield b'\0'
        now = 0
        for _ in range(1200):
            operation = rng.choices(range(1, 9), weights=[14, 35, 18, 6, 6, 10, 6, 5])[0]
            if operation == 1:
                now += rng.choice([0, 1, 1_000_000, 16_000_000, 2_000_000_000, 5_000_000_000])
                yield frame(now)
            elif operation == 2:
                yield request(rng.randrange(1, 65), rng.randrange(1, 9), rng.choice([1, 2, 3, 7, 31, 2**64 - 1]), rng.choice([(1, 1), (2, 2), (32, 64), (640, 480), (8192, 4096), (16384, 8192), (16384, 16384), (16385, 1)]), rng.choice([0, quota // 2, quota - 1, quota, quota + 1]), now)
            elif operation == 3:
                yield complete(rng.choice([0, 1, 2, 3, 4, rng.randrange(1, 513), 513]), rng.randrange(2), now)
            elif operation in [4, 5]:
                yield bytes([operation]) + struct.pack('<I', rng.randrange(514))
            elif operation == 6:
                yield sweep(rng.choice([0, all_bits, rng.getrandbits(64)]), rng.choice([0, all_bits, rng.getrandbits(64)]))
            elif operation == 7:
                yield b'\7' + identity(rng.randrange(1, 65), rng.randrange(1, 9), 1)
            else:
                yield b'\10' + struct.pack('<Q', now)


def prepare(root, work):
    sources = [root / name for name in ['src/gui/image/GpuImages.zig', 'lib/gfx/ImageUpload.zig', 'src/client/graphics/ImageIdentity.zig', 'src/gui/image/pane_images.zig', 'src/gui/GuiAdapter.zig', 'src/core/graphics.zig']]
    for source in sources[:3]:
        shutil.copy2(source, work / source.name)
    original = sources[3].read_text()
    constants = '\n'.join(re.search(rf'^const {name}[^;]*;', original, re.MULTILINE).group(0) for name in ['rgba_bytes', 'uploads_per_image', 'spare_limit', 'spare_ttl_ns', 'idle_ttl_ns'])
    names = ['takeRow', 'reserve', 'evictOne', 'retire', 'discard', 'expiry', 'trim', 'sweep', 'wakeupAfter', 'trimDue', 'markStandIns', 'noteDrawn']
    functions = '\n\n'.join(function_source(original, name) for name in names)
    completion = re.search(r'(?m)^                self\.images\.gpu\.uploading -= 1;.*?^                break :ret null;', sources[4].read_text(), re.DOTALL).group(0).replace('self.images.', 'images.')
    (work / 'probe.zig').write_text(reference.replace('__CONSTANTS__', constants).replace('__FUNCTIONS__', functions).replace('__COMPLETION__', completion))
    quota = re.search(r'^pub const max_image_bytes_global[^;]*;', sources[5].read_text(), re.MULTILINE).group(0)
    (work / 'core.zig').write_text('pub const PaneId = enum(u64) { _ };\n' + quota + '\n')
    (work / 'gfx.zig').write_text('pub const ImageUpload = @import("ImageUpload.zig");\npub const ImageDraw = struct { pub const ImageDraw = struct { handle: u32 }; };\n')
    (work / 'client.zig').write_text('pub const ImageIdentity = @import("ImageIdentity.zig");\npub const retained_graphics = struct { pub const Lease = struct {}; };\n')
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'gfx', '--dep', 'telar-client', '--dep', 'telar-core', f'-Mroot={work / "probe.zig"}', f'-Mgfx={work / "gfx.zig"}', '--dep', 'telar-core', f'-Mtelar-client={work / "client.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command, sources, names


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command, sources, functions = prepare(root, work)
    cases = list(fixtures())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-image-residency-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        record_format = '<IBB' + 'Q' * 10 + 'IB'
        record_size = struct.calcsize(record_format)
        index = offset // record_size
        decode = lambda data: struct.unpack_from(record_format, data, index * record_size)
        raise RuntimeError(f'Image residency mismatch at operation {index}, byte {offset}: operation={cases[index].hex()}, original={decode(expected)}, cpp={decode(actual)}')
    sources += [Path(__file__), root / 'services/gui-cpp/graphics/image_residency.hpp', root / 'services/gui-cpp/graphics/lifetime.hpp', root / 'dlls/telar-config/include/telar_config/graphics/limits.hpp', root / 'services/gui-cpp/tools/image_residency_probe.cpp', root / 'services/gui-cpp/tools/probe_io.hpp', root / 'services/gui-cpp/tools/check_notification_center.py', root / 'services/gui-cpp/tools/check_task_labels.py']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, reference_command=command, unchanged_functions=functions, scope='Original GpuImages table, allocation/eviction/retirement/expiry functions and original completion transition block. The adapter supplies accepted metadata and retained-byte totals and assumes successful pixel retention, reproducing upload admission bounds without executing the store or native backend. Compares admission, stable handles, stages and fields of occupied rows, dense order, releases, revisions, presentation counts and deadlines after each operation. Does not establish Qt resource integration, actual memory use, lease safety, asynchronous native failure, visuals or performance.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Matched {len(cases)} original image residency operations: {result["output_sha256"]}')


if __name__ == '__main__':
    main()
