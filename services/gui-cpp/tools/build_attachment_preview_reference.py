import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from check_task_labels import function_source


probe = r'''
const std = @import("std");
const filter = @import("box_filter.zig");
const alpha = @import("premultiply.zig");
const ImageView = @import("ImageView.zig");
extern "c" fn putchar(c_int) c_int;
const Sizing = struct {
__FIT__
};
const Shift = enum(u6) { first = 13, second = 7, third = 17 };
const fit_count: usize = 16384;
const maximum_side: u32 = 2048;
const maximum_pixels: u32 = 2 * 1024 * 1024;
const channel_max: u64 = 255;
const rectangles = [_][4]u32{
    .{ 1, 1, 1, 1 }, .{ 2, 3, 2, 3 }, .{ 3, 2, 2, 1 },
    .{ 17, 9, 7, 4 }, .{ 64, 65, 13, 31 }, .{ 257, 129, 256, 128 },
    .{ 70000, 1, 2048, 1 }, .{ 1, 70000, 1, 256 },
};

fn randomWord(state: *u64) u64 {
    state.* ^= state.* << @intFromEnum(Shift.first);
    state.* ^= state.* >> @intFromEnum(Shift.second);
    state.* ^= state.* << @intFromEnum(Shift.third);

    return state.*;
}

fn write(value: u64) !void {
    for (0..@sizeOf(u64)) |index| {
        const shift: u6 = @intCast(index * @bitSizeOf(u8));
        if (putchar(@intCast((value >> shift) & channel_max)) < 0) {
            return error.WriteFailed;
        }
    }
}

pub fn main() !void {
    var random: u64 = 0x9e3779b97f4a7c15;
    for (0..fit_count) |_| {
        const width = @as(u32, @truncate(randomWord(&random))) | 1;
        const height = @as(u32, @truncate(randomWord(&random))) | 1;
        const size = Sizing.fit(width, height, maximum_side, maximum_pixels);
        for ([_]u64{ width, height, size[0], size[1] }) |value| {
            try write(value);
        }
    }

    const gpa = std.heap.c_allocator;
    for (rectangles) |shape| {
        const input = try gpa.alloc(u8, @as(usize, shape[0]) * shape[1] * 4);
        defer gpa.free(input);
        const output = try gpa.alloc(u8, @as(usize, shape[2]) * shape[3] * 4);
        defer gpa.free(output);
        for (input) |*byte| {
            byte.* = @truncate(randomWord(&random));
        }
        const image: ImageView = .{ .pixels = input, .stride = shape[0] * 4, .width = shape[0], .height = shape[1] };
        filter.resampleRect(image, output, shape[2], shape[3]);
        alpha.inPlace(output);
        for (shape) |value| {
            try write(value);
        }
        for (output) |byte| {
            if (putchar(byte) < 0) {
                return error.WriteFailed;
            }
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description="Build the unchanged original fit, area resampling and premultiplication oracle")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = {}
    for name in ("box_filter.zig", "premultiply.zig", "ImageView.zig"):
        source = repository / "lib/imaging" / name
        shutil.copy2(source, output / name)
        sources[str(source.relative_to(repository))] = hashlib.sha256(source.read_bytes()).hexdigest()
    original = repository / "src/gui/image/preview_decode.zig"
    sources[str(original.relative_to(repository))] = hashlib.sha256(original.read_bytes()).hexdigest()
    fitted = function_source(original.read_text(), "fit")
    (output / "probe.zig").write_text(probe.replace("__FIT__", fitted))
    binary = output / "attachment-preview-reference"
    command = ["zig", "build-exe", "-O", "ReleaseFast", "-lc", str(output / "probe.zig"), "-femit-bin=" + str(binary)]
    with (output / "build.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, cwd=repository)
    receipt = {"command": command, "source_sha256": sources, "exit_code": result.returncode, "scope": "Unchanged original fit function and imaging source files. Rectangles include non-square reductions and 70000x1/1x70000."}
    (output / "build.json").write_text(json.dumps(receipt, indent=2))
    result.check_returncode()
    receipt["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    (output / "build.json").write_text(json.dumps(receipt, indent=2))
    print("Original preview sizing/filter reference built")


if __name__ == "__main__":
    main()
