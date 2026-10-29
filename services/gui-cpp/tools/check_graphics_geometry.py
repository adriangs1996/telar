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
from check_graphics_store import key


reference = r'''
const std = @import("std");
const kitty = @import("kitty_protocol");
const core = struct { pub const RectRect = @import("Rect.zig"); };
const Image = @import("Image.zig");
const Placement = @import("Placement.zig");
const GpuImages = struct { width: [1]u32, height: [1]u32 };
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn readKey() !@import("ImageKey.zig") { return .{.image_id = try read(u32), .generation = try read(u64)}; }
fn readImage() !Image {
    const identity = try readKey(); const format = try read(u8); const width = try read(u32); const height = try read(u32);
    return .{.key = identity, .format = @enumFromInt(format), .width = width, .height = height, .byte_len = try read(u64)};
}
fn readPlacement() !Placement {
    return .{.key = try readKey(), .virtual_id = try read(u64), .placement_id = try read(u32), .x = try read(i32), .y = try read(i32), .source_x = try read(u32), .source_y = try read(u32), .source_width = try read(u32), .source_height = try read(u32), .columns = try read(u32), .rows = try read(u32), .offset_x = try read(u32), .offset_y = try read(u32), .z_index = try read(i32), .location = @enumFromInt(try read(u8))};
}
__UV__
pub fn main() !void {
    while (true) {
        const command = getchar(); if (command < 0) return;
        const image = try readImage(); const placement = try readPlacement();
        const gpu: GpuImages = .{.width = .{try read(u32)}, .height = .{try read(u32)}};
        const cell_width = try read(u32); const cell_height = try read(u32); _ = try read(f32);
        const source = try placement.sourceRect(image);
        const box = kitty.box(.{.source_width = @intCast(source.width), .source_height = @intCast(source.height), .columns = placement.columns, .rows = placement.rows, .offset_x = placement.offset_x, .offset_y = placement.offset_y, .cell_width = cell_width, .cell_height = cell_height});
        try write(@as(i64, placement.x) * cell_width + box.offset_x);
        try write(@as(i64, placement.y) * cell_height + box.offset_y);
        try write(box.width); try write(box.height);
        for (uvOf(&gpu, 0, source)) |value| { try write(value); }
    }
}
'''


def fixtures():
    rng = random.Random(0x1A6E)
    maximum = 2**32 - 1
    configurations = itertools.product([1, 1.25, 1.5, 2, 3], [(1, 1), (13, 29), (16, 32)], [(0, 0), (1, 0), (0, 1), (2, 3), (17, 31), (maximum, 1)])
    for scale, cell, grid in configurations:
        for _ in range(32):
            width, height = rng.choice([(2, 2), (640, 480), (4096, 2160), (1, 8192)])
            source_x, source_y = rng.randrange(width), rng.randrange(height)
            source_width = rng.choice([0, width - source_x])
            source_height = rng.choice([0, height - source_y])
            texture = rng.choice([(width, height), (1, 1), (2, 2), (32, 64), (16384, 16384)])
            image = key() + struct.pack('<BIIQ', 32, width, height, width * height * 4)
            placement = key() + struct.pack('<QIiiIIIIIIIIiB', 1, 1, rng.randrange(-8, 9), rng.randrange(-8, 9), source_x, source_y, source_width, source_height, *grid, rng.choice([0, 1, 31, maximum]), rng.choice([0, 1, 31, maximum]), 0, 0)
            yield b'\0' + image + placement + struct.pack('<IIIIf', *texture, *cell, scale)


def prepare(root, work):
    sources = []
    for name in ['Image.zig', 'ImageKey.zig', 'Placement.zig', 'PlacementLocation.zig', 'Rect.zig']:
        path = root / 'src/core' / name
        shutil.copy2(path, work / name)
        sources.append(path)
    kitty = work / 'kitty'
    kitty.mkdir()
    for name in ['image_support.zig', 'display.zig', 'DisplayBox.zig', 'DisplayCells.zig', 'DisplayRequest.zig', 'Layer.zig']:
        path = root / 'lib/kitty_protocol' / name
        shutil.copy2(path, kitty / name)
        sources.append(path)
    (kitty / 'root.zig').write_text('pub const Format = @import("image_support.zig").Format;\npub const box = @import("display.zig").box;\n')
    uv_path = root / 'src/gui/image/pane_images.zig'
    (work / 'probe.zig').write_text(reference.replace('__UV__', function_source(uv_path.read_text(), 'uvOf')))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'kitty_protocol', f'-Mroot={work / "probe.zig"}', f'-Mkitty_protocol={kitty / "root.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command, sources + [uv_path]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command, sources = prepare(root, work)
    cases = list(fixtures())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-graphics-geometry-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        record_size = struct.calcsize('<qqIIffff')
        index = offset // record_size
        decode = lambda data: struct.unpack_from('<qqIIffff', data, index * record_size)
        raise RuntimeError(f'Graphics geometry mismatch in record {index}, byte {offset}: original={decode(expected)}, cpp={decode(actual)}')
    sources += [Path(__file__), root / 'services/gui-cpp/graphics/placement.hpp', root / 'services/gui-cpp/graphics/display_box.hpp', root / 'services/gui-cpp/graphics/source_rect.hpp', root / 'services/gui-cpp/tools/check_graphics_store.py', root / 'services/gui-cpp/tools/graphics_geometry_probe.cpp', root / 'services/gui-cpp/tools/probe_graphics.hpp']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, reference_command=command, scope='Original placement validation, integer Kitty display box and unchanged stand-in UV resolution. Compares physical bounds and UV floats for valid placements at five densities. Excludes placeholder fragments, clipping, allocation, ordering, uploads and native pixels.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Matched {len(cases)} original graphics geometry records: {result["output_sha256"]}')


if __name__ == '__main__':
    main()
