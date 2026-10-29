import argparse
import datetime
from enum import IntEnum
import hashlib
import json
from pathlib import Path
import random
import re
import struct
import subprocess

from check_notification_center import function_source, run


maximum_uv_error = 0.000001


class Operation(IntEnum):
    draw = 1
    begin_frame = 2


reference = r'''
const std = @import("std");
const capacity = __CAPACITY__;
const Operation = enum(c_int) { draw = 1, begin_frame = 2 };
const Rect = struct { x: f32, y: f32, width: f32, height: f32 };
const Quad = struct { x: f32, y: f32, width: f32, height: f32, u0: f32, v0: f32, u1: f32, v1: f32, r: f32, g: f32, b: f32, a: f32, texture: f32 };
const gfx = struct { const Quad = struct { const image_texture: f32 = 1; }; };
const ImageTarget = struct { handle: u32, bounds: Rect };
__CLIP__
const Quads = struct {
    storage: [capacity]Quad = undefined,
    count: usize = 0,
    last: ?Quad = null,
    fn items(self: *@This()) []Quad { return self.storage[0..self.count]; }
    fn pushClipped(self: *@This(), item: Quad, bounds: Rect) !void {
        const visible = clipQuad(item, bounds);
        if (visible.width > 0 and visible.height > 0) {
            self.count += 1;
            self.last = visible;
        }
    }
};
const Renderer = struct {
    quads: Quads = .{},
    image_draws: [capacity]struct { quad: u32, handle: u32 } = undefined,
    image_draw_count: u32 = 0,
__PUSH__
};
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
fn readRect() !Rect { return .{.x = try read(f32), .y = try read(f32), .width = try read(f32), .height = try read(f32)}; }
pub fn main() !void {
    var renderer: Renderer = .{};
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        if (operation == @intFromEnum(Operation.begin_frame)) { renderer = .{}; continue; }
        if (operation != @intFromEnum(Operation.draw)) return error.UnknownOperation;
        const source = try readRect(); const destination = try readRect(); const bounds = try readRect(); const handle = try read(u32);
        const before = renderer.image_draw_count;
        const accepted = try renderer.pushImage(destination, .{source.x, source.y, source.x + source.width, source.y + source.height}, .{.handle = handle, .bounds = bounds});
        const drawn = renderer.image_draw_count != before;
        try write(@as(u8, @intFromBool(accepted)));
        try write(renderer.image_draw_count);
        try write(if (drawn) handle else @as(u32, 0));
        const values: [8]f32 = if (drawn) output: {
            const quad = renderer.quads.last.?;
            break :output .{quad.x, quad.y, quad.width, quad.height, quad.u0, quad.v0, quad.u1, quad.v1};
        } else @splat(0);
        for (values) |value| { try write(value); }
    }
}
'''


def push(source, destination, bounds, handle):
    return bytes([Operation.draw]) + struct.pack('<12fI', *source, *destination, *bounds, handle)


def fixtures(capacity):
    source = (0, 0, 1, 1)
    visible = (0, 0, 64, 64)
    outside = (128, 128, 64, 64)
    for _ in range(4):
        yield bytes([Operation.begin_frame])
        for index in range(capacity + 16):
            yield push(source, outside if index % 7 == 0 else visible, visible, (index % 512) + 1)
        for _ in range(capacity):
            yield push(source, visible, visible, 1)
        yield push(source, outside, visible, 1)
    generator = random.Random(0xD2A5)
    for scale in (1, 1.25, 1.5, 2, 3):
        for _ in range(12):
            yield bytes([Operation.begin_frame])
            for _ in range(128):
                source = tuple(generator.randrange(1, 64) / 64 for _ in range(4))
                destination = tuple(generator.randrange(-32, 128) / scale for _ in range(4))
                bounds = tuple(generator.randrange(0, 64) / scale for _ in range(4))
                yield push(source, destination, bounds, generator.randrange(1, 513))


def compare(expected, actual):
    row = struct.Struct('<BII8f')
    if len(expected) != len(actual) or len(expected) % row.size:
        raise RuntimeError('The draw observations have inconsistent lengths')
    maximum_uv_difference = 0
    for index, (left, right) in enumerate(zip(row.iter_unpack(expected), row.iter_unpack(actual))):
        if left[:7] != right[:7]:
            raise RuntimeError(f'Draw admission, count, handle or clipped destination differs at observation {index}: {left} != {right}')
        difference = max(abs(a - b) for a, b in zip(left[7:], right[7:]))
        maximum_uv_difference = max(maximum_uv_difference, difference)
        if difference > maximum_uv_error:
            raise RuntimeError(f'Texture coordinates differ beyond one millionth at observation {index}: {left} != {right}')
    return len(expected) // row.size, maximum_uv_difference


def main():
    parser = argparse.ArgumentParser(description='Compare image admission and clipping against original renderer functions')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    original = root / 'lib/gfx/ImageDraw.zig'
    capacity = int(re.search(r'pub const capacity = (\d+);', original.read_text())[1])
    renderer = root / 'src/gui/render/Renderer.zig'
    quads = root / 'lib/gfx/QuadList.zig'
    source = reference.replace('__CAPACITY__', str(capacity)).replace('__CLIP__', function_source(quads.read_text(), 'clipQuad')).replace('__PUSH__', function_source(renderer.read_text(), 'pushImage'))
    (output / 'probe.zig').write_text(source)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    data = b''.join(fixtures(capacity))
    (output / 'input.bin').write_bytes(data)
    expected = run(output / 'original', data, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-graphics-geometry-probe', data, output, 'cpp')
    observations, difference = compare(expected, actual)
    sources = [original, renderer, quads, root / 'services/gui-cpp/graphics/image_draw_budget.hpp', root / 'services/gui-cpp/graphics/placement.hpp', root / 'services/gui-cpp/tools/graphics_geometry_probe.cpp', root / 'services/gui-cpp/tools/check_notification_center.py', root / 'services/gui-cpp/tools/check_task_labels.py', Path(__file__).resolve()]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), observations=observations, capacity=capacity, input_sha256=hashlib.sha256(data).hexdigest(), original_output_sha256=hashlib.sha256(expected).hexdigest(), cpp_output_sha256=hashlib.sha256(actual).hexdigest(), maximum_normalized_uv_difference=difference, source_sha256={str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, reference_command=command, unchanged_functions=['pushImage', 'clipQuad'], scope='Validated positive source rectangles, finite destinations and clips. Original pushImage and clipQuad bodies are unchanged; the adapter supplies a fixed quad table and counter. Admission, cumulative counts, handles and destination floats match exactly; normalized texture coordinates may differ by at most one millionth from rectangle/endpoint arithmetic. This does not cover global placement selection, texture readiness, native draws, visuals or performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'{observations} original renderer observations match; maximum normalized UV difference {difference}')


if __name__ == '__main__':
    main()
