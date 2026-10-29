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

from check_notification_center import run


reference = r'''
const std = @import("std");
const core = @import("telar-core");
const retained = @import("retained.zig");
const Store = retained.Store;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn readKey() !core.ImageKey { return .{.image_id = try read(u32), .generation = try read(u64)}; }
fn writeKey(key: core.ImageKey) !void { try write(key.image_id); try write(key.generation); }
fn readImage() !core.Image {
    const key = try readKey();
    const format = try read(u8);
    const width = try read(u32);
    const height = try read(u32);
    return .{.key = key, .format = @enumFromInt(format), .width = width, .height = height, .byte_len = try read(u64)};
}
fn writeImage(image: core.Image) !void {
    try writeKey(image.key);
    try write(@as(u8, @intFromEnum(image.format)));
    try write(image.width); try write(image.height); try write(image.byte_len);
}
fn readPlacement() !core.Placement {
    return .{.key = try readKey(), .virtual_id = try read(u64), .placement_id = try read(u32), .x = try read(i32), .y = try read(i32), .source_x = try read(u32), .source_y = try read(u32), .source_width = try read(u32), .source_height = try read(u32), .columns = try read(u32), .rows = try read(u32), .offset_x = try read(u32), .offset_y = try read(u32), .z_index = try read(i32), .location = @enumFromInt(try read(u8))};
}
fn writePlacement(placement: core.Placement) !void {
    try writeKey(placement.key); try write(placement.virtual_id); try write(placement.placement_id);
    try write(placement.x); try write(placement.y); try write(placement.source_x); try write(placement.source_y);
    try write(placement.source_width); try write(placement.source_height); try write(placement.columns); try write(placement.rows);
    try write(placement.offset_x); try write(placement.offset_y); try write(placement.z_index); try write(@as(u8, @intFromEnum(placement.location)));
}
fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| { hash = (hash ^ byte) *% 1099511628211; }
    return hash;
}
fn apply(store: *Store, operation: u8) !void {
    const pane_id: core.PaneId = @enumFromInt(try read(u8));
    const revision = try read(u64);
    switch (operation) {
        1 => try store.applySnapshot(.{.pane_id = pane_id, .revision = revision, .phase = @enumFromInt(try read(u8))}),
        2 => try store.applyImage(.{.pane_id = pane_id, .revision = revision, .image = try readImage()}),
        3 => {
            const key = try readKey(); const offset = try read(u64);
            const bytes = try std.heap.page_allocator.alloc(u8, try read(u16)); defer std.heap.page_allocator.free(bytes);
            for (bytes) |*byte| { byte.* = try read(u8); }
            try store.applyChunk(.{.pane_id = pane_id, .revision = revision, .key = key, .offset = offset, .bytes = bytes});
        },
        4 => try store.applyPlacement(.{.pane_id = pane_id, .revision = revision, .placement = try readPlacement()}),
        5 => try store.deleteImage(.{.pane_id = pane_id, .revision = revision, .key = try readKey()}),
        6 => try store.deletePlacement(.{.pane_id = pane_id, .revision = revision, .key = try readKey(), .virtual_id = try read(u64), .placement_id = try read(u32)}),
        7 => store.clearPane(pane_id),
        else => return error.InvalidOperation,
    }
}
fn errorCode(failed: anyerror) u8 {
    return switch (failed) {
        error.GraphicsResyncRequired => 1,
        error.GraphicsImageLimitExceeded => 2,
        error.GraphicsPlacementLimitExceeded => 3,
        error.GraphicsChunkLimitExceeded => 4,
        error.GraphicsQuotaExceeded, error.ImageQuotaExceeded => 5,
        else => 6,
    };
}
fn state(store: *Store, outcome: u8) !void {
    try write(outcome); try write(@as(u64, @intCast(store.total_bytes)));
    for (1..5) |pane| {
        const pane_id: core.PaneId = @enumFromInt(pane);
        const usage = store.usage.getPtr(pane_id);
        const credit = if (usage) |value| value.released_bytes else 0;
        try write(@as(u64, @intCast(credit)));
        if (credit != 0) { store.consumeCredit(.{.pane_id = pane_id, .bytes = credit}); }
        var images: std.ArrayList(Store.ImageEntry) = .empty; defer images.deinit(std.heap.page_allocator);
        var iterator = store.images.iterator();
        while (iterator.next()) |entry| { if (entry.key_ptr.pane_id == pane_id) { try images.append(std.heap.page_allocator, entry.value_ptr.*); } }
        const Order = struct {
            fn image(_: void, left: Store.ImageEntry, right: Store.ImageEntry) bool {
                return if (left.metadata.key.image_id == right.metadata.key.image_id) left.metadata.key.generation < right.metadata.key.generation else left.metadata.key.image_id < right.metadata.key.image_id;
            }
            fn placement(_: void, left: core.Placement, right: core.Placement) bool { return left.virtual_id < right.virtual_id; }
        };
        std.mem.sort(Store.ImageEntry, images.items, {}, Order.image);
        try write(@as(u32, @intCast(images.items.len)));
        for (images.items) |image| {
            try writeImage(image.metadata); try write(@as(u64, @intCast(image.received)));
            try write(@as(u8, @intFromBool(image.retire_pending))); try write(checksum(image.pixels[0..image.received]));
        }
        var placements: std.ArrayList(core.Placement) = .empty; defer placements.deinit(std.heap.page_allocator);
        var placement_iterator = store.placements.iterator();
        while (placement_iterator.next()) |entry| { if (entry.key_ptr.pane_id == pane_id) { try placements.append(std.heap.page_allocator, entry.value_ptr.placement); } }
        std.mem.sort(core.Placement, placements.items, {}, Order.placement);
        try write(@as(u32, @intCast(placements.items.len)));
        for (placements.items) |placement| { try writePlacement(placement); }
    }
}
pub fn main() !void {
    var store = Store.init(std.heap.page_allocator); defer store.deinit();
    while (true) {
        const operation = getchar(); if (operation < 0) return;
        var outcome: u8 = 0;
        if (operation == 0) { store.deinit(); store = Store.init(std.heap.page_allocator); }
        else { apply(&store, @intCast(operation)) catch |failed| { outcome = errorCode(failed); }; }
        try state(&store, outcome);
    }
}
'''


def prepare(root, work):
    client = root / 'src/client/graphics'
    names = ['GenericResourceStore.zig', 'retained.zig', 'state.zig', 'ImageState.zig', 'placement_state.zig', 'Lease.zig', 'ImageIdentity.zig', 'PlacementIdentity.zig', 'Credit.zig', 'store.zig']
    sources = [client / name for name in names]
    for source in sources:
        shutil.copy2(source, work / source.name)
    core = work / 'core'
    (core / 'schema').mkdir(parents=True)
    core_names = ['Image.zig', 'ImageKey.zig', 'Placement.zig', 'PlacementLocation.zig', 'Rect.zig', 'ShmName.zig', 'graphics.zig', 'limit_reached.zig', 'Limit.zig', 'LimitReach.zig', 'LimitReaches.zig', 'RecordedReach.zig', 'ReachTime.zig', 'GenericSlotIndex.zig']
    for name in core_names:
        path = root / 'src/core' / name
        shutil.copy2(path, core / name)
        sources.append(path)
    schema_names = ['Snapshot.zig', 'Image.zig', 'ImageChunk.zig', 'Placement.zig', 'DeleteImage.zig', 'DeletePlacement.zig']
    for name in schema_names:
        path = root / 'src/core/schema' / name
        shutil.copy2(path, core / 'schema' / name)
        sources.append(path)
    (core / 'schema/id.zig').write_text('pub const PaneId = enum(u64) {_};\n')
    phase_source = root / 'src/core/schema/graphics.zig'
    phase = re.search(r'pub const SnapshotPhase = enum\(u8\) \{[^}]*\};', phase_source.read_text()).group()
    (core / 'schema/graphics.zig').write_text(phase + '\n')
    exports = {name.removesuffix('.zig'): name for name in ['Image.zig', 'ImageKey.zig', 'Placement.zig', 'ShmName.zig', 'limit_reached.zig']}
    exports.update(Snapshot='schema/Snapshot.zig', SchemaImage='schema/Image.zig', ImageChunk='schema/ImageChunk.zig', SchemaPlacement='schema/Placement.zig', DeleteImage='schema/DeleteImage.zig', DeletePlacement='schema/DeletePlacement.zig')
    facade = '\n'.join(f'pub const {name} = @import("{path}");' for name, path in exports.items())
    facade += '\npub const PaneId = @import("schema/id.zig").PaneId;\nconst graphics = @import("graphics.zig");\n'
    facade += '\n'.join(f'pub const {name} = graphics.{name};' for name in ['max_image_bytes_per_pane', 'max_image_bytes_global', 'max_images_per_pane', 'max_placements_per_pane', 'max_chunks_per_image'])
    (core / 'root.zig').write_text(facade + '\n')
    kitty_source = root / 'lib/kitty_protocol/image_support.zig'
    shutil.copy2(kitty_source, work / 'image_support.zig')
    (work / 'kitty.zig').write_text('pub const Format = @import("image_support.zig").Format;\n')
    (work / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'telar-core', '--dep', 'privatefile', f'-Mroot={work / "probe.zig"}', '--dep', 'kitty_protocol', f'-Mtelar-core={core / "root.zig"}', f'-Mprivatefile={root / "lib/privatefile/root.zig"}', f'-Mkitty_protocol={work / "kitty.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command, sources + [phase_source, kitty_source, root / 'lib/privatefile/root.zig', root / 'lib/privatefile/Inode.zig']


def key(identifier=1, generation=1):
    return struct.pack('<IQ', identifier, generation)


def operation(code, revision=1, pane=1):
    return struct.pack('<BBQ', code, pane, revision)


def snapshot(phase, revision=1, pane=1):
    return operation(1, revision, pane) + bytes([phase])


def image(identifier=1, generation=1, side=2, revision=1, pane=1, format=32):
    return operation(2, revision, pane) + key(identifier, generation) + struct.pack('<BIIQ', format, side, side, side * side * (format // 8))


def chunk(identifier=1, generation=1, pixels=bytes(16), offset=0, revision=1, pane=1):
    return operation(3, revision, pane) + key(identifier, generation) + struct.pack('<QH', offset, len(pixels)) + pixels


def placement(identifier=1, generation=1, virtual=1, revision=1, pane=1, source=(0, 0, 0, 0)):
    return operation(4, revision, pane) + key(identifier, generation) + struct.pack('<QIiiIIIIIIIIiB', virtual, 1, 0, 0, *source, 1, 1, 0, 0, 0, 0)


def delete_placement(identifier=1, generation=1, virtual=1, revision=1, pane=1):
    return operation(6, revision, pane) + key(identifier, generation) + struct.pack('<QI', virtual, 0)


def records():
    yield b'\0'
    for invalid in [{'identifier': 0}, {'generation': 0}, {'side': 0}]:
        yield image(**invalid)
    invalid_length = bytearray(image())
    invalid_length[-1] ^= 1
    yield bytes(invalid_length)
    yield b'\0'
    yield image(format=24)
    yield chunk(pixels=bytes(range(12)))
    yield placement()
    yield b'\0'
    yield image()
    yield chunk(pixels=bytes(range(16)))
    yield placement()
    yield image(generation=2)
    yield chunk(generation=2, pixels=bytes(range(16, 32)))
    yield delete_placement(generation=2)
    yield b'\0'
    for generation in range(1, 270):
        yield image(generation=generation)
        yield placement(generation=generation, virtual=generation)
        yield chunk(generation=generation)
    yield snapshot(0, revision=2)
    yield image(revision=2)
    yield placement(revision=2)
    yield snapshot(1, revision=2)
    yield b'\0'
    for identifier in range(1, 66):
        yield image(identifier)
    yield operation(5) + key()
    yield snapshot(1)
    yield snapshot(0, revision=2)
    yield image(revision=3)
    yield b'\0'
    yield image(side=8192)
    yield image(identifier=2)
    yield snapshot(0, revision=2)
    for pane in [1, 2, 3]:
        yield image(side=8192, pane=pane, revision=2)
    yield operation(7, pane=1)
    yield image(side=8192, pane=3, revision=3)
    yield b'\0'
    yield image()
    for _ in range(43_691):
        yield chunk(pixels=b'')
    yield b'\0'
    rng = random.Random(0x6A4F1C)
    for _ in range(8):
        yield b'\0'
        revision = 1
        for _ in range(650):
            pane = rng.randrange(1, 5)
            identifier = rng.randrange(1, 12)
            generation = rng.randrange(1, 9)
            selected = rng.randrange(10)
            if selected < 3:
                yield image(identifier, generation, revision=revision, pane=pane)
            elif selected < 5:
                yield chunk(identifier, generation, pixels=rng.randbytes(rng.choice([0, 8, 16])), offset=rng.choice([0, 8]), revision=revision, pane=pane)
            elif selected < 7:
                yield placement(identifier, generation, virtual=rng.randrange(1, 20), revision=revision, pane=pane, source=rng.choice([(0, 0, 0, 0), (1, 1, 1, 1), (2, 0, 0, 0)]))
            elif selected == 7:
                yield delete_placement(identifier, generation, virtual=rng.randrange(1, 20), revision=revision, pane=pane)
            elif selected == 8:
                yield operation(5, revision, pane) + key(identifier, generation)
            else:
                revision += rng.randrange(2)
                yield snapshot(rng.randrange(2), revision=revision, pane=pane)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command, sources = prepare(root, work)
    cases = list(records())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-graphics-store-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Graphics store mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources += [Path(__file__), root / 'services/gui-cpp/graphics/store.hpp', root / 'services/gui-cpp/tools/graphics_store_probe.cpp', root / 'services/gui-cpp/tools/probe_graphics.hpp']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, reference_command=command, scope='Unmodified GenericResourceStore and retained delivery policy, real image/placement validation and wire value structs with a PaneId facade. Compares four-pane CPU budgets, exact metadata, initialized pixel-prefix checksums, retirement, placements, released credits and outcome categories after every operation. No live leases, shared-memory mapping, GPU caches, revision counters or native pixels. Non-limit malformed errors are grouped together.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Matched {len(cases)} original graphics store operations: {result["output_sha256"]}')


if __name__ == '__main__':
    main()
