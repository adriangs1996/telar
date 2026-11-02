import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<17I")
length_format = struct.Struct("<I")

cpp_probe = r"""
#include "input/child_mouse.hpp"
#include "input/mouse_encoder.hpp"
#include <cstdint>
#include <iostream>

using namespace telar::gui;
struct Request {
  std::uint32_t tracking, sgr, pixels, phase, button, modifiers;
  std::uint32_t columns, rows, content_columns, content_rows, origin_x, origin_y;
  std::uint32_t cell_width, cell_height, scale, x, y;
};
int main() {
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    const ChildMouseView view{
      .pane_id = 1,
      .surface = {.content = {.x = float(request.origin_x * request.cell_width), .y = float(request.origin_y * request.cell_height), .width = float(request.content_columns * request.cell_width), .height = float(request.content_rows * request.cell_height)}, .cell = {.x = float(request.cell_width), .y = float(request.cell_height)}, .scale = float(request.scale)},
      .protocol = {.tracking = telar::MouseTracking(request.tracking), .sgr = request.sgr != 0, .pixels = request.pixels != 0},
      .columns = std::uint16_t(request.columns), .rows = std::uint16_t(request.rows),
      .cell_width_px = std::uint16_t(request.cell_width * request.scale), .cell_height_px = std::uint16_t(request.cell_height * request.scale), .attached = true,
    };
    const ChildMouseSample sample{.button = MouseButton(request.button), .phase = MousePhase(request.phase), .position = {.x = float(request.x), .y = float(request.y)}, .modifiers = request.modifiers};
    const auto report = ChildMouseProjection::project(view, sample);
    MouseEncoder encoder;
    const auto bytes = report ? encoder.encode(report->button, report->x, report->y, report->released, true) : std::string_view{};
    const auto length = std::uint32_t(bytes.size());
    std::cout.write(reinterpret_cast<const char *>(&length), sizeof(length));
    std::cout.write(bytes.data(), bytes.size());
  }
}
"""

zig_probe = r"""
const std = @import("std");
const keyinput = @import("keyinput");
const PixelProjection = keyinput.PixelProjection;
const core = @import("telar-core");
const cellgrid = @import("cellgrid");
const data = @import("model");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct {
    tracking: u32, sgr: u32, pixels: u32, phase: u32, button: u32, modifiers: u32,
    columns: u32, rows: u32, content_columns: u32, content_rows: u32, origin_x: u32, origin_y: u32,
    cell_width: u32, cell_height: u32, scale: u32, x: u32, y: u32,
};

fn reference(request: Request, buffer: []u8) !?[]const u8 {
    const kinds = [_]keyinput.Mouse.Kind{ .press, .drag, .release, .move };
    const kind = kinds[request.phase];
    const tracking: keyinput.MouseTracking = @enumFromInt(request.tracking);
    if (request.sgr == 0 or !keyinput.tracked(tracking, kind)) return null;
    const capture = .{
        .content = cellgrid.Rect{ .x = @intCast(request.origin_x), .y = @intCast(request.origin_y), .w = @intCast(request.content_columns), .h = @intCast(request.content_rows) },
        .cell_width = @as(u16, @intCast(request.cell_width * request.scale)),
        .cell_height = @as(u16, @intCast(request.cell_height * request.scale)),
    };
    const self = &capture;
    const pane = .{ .buffer = .{ .w = @as(u16, @intCast(request.columns)), .h = @as(u16, @intCast(request.rows)) } };
    const event: keyinput.Mouse = .{
        .x = @intCast(request.x / request.cell_width), .y = @intCast(request.y / request.cell_height),
        .raw_x = request.x * request.scale, .raw_y = request.y * request.scale,
        .kind = kind, .button = @intCast(request.button | request.modifiers | @as(u32, if (kind == .drag or kind == .move) 32 else 0)),
    };
    RETAINED_PROJECTION
    return try encodeReport(buffer, .{
        .plan = .{ .pane_id = @enumFromInt(1), .content = content, .protocol = .{ .tracking = tracking, .sgr = true, .pixels = request.pixels != 0 }, .alternate_scroll = false, .at_bottom = true },
        .command = .{ .event = projected, .exterior_pixels = true, .cell_width_px = self.cell_width, .cell_height_px = self.cell_height },
    });
}

fn readExact(bytes: []u8) bool {
    var offset: usize = 0;
    while (offset != bytes.len) {
        const count = read(0, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return false;
        offset += @intCast(count);
    }
    return true;
}

fn writeAll(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset != bytes.len) {
        const count = write(1, bytes[offset..].ptr, bytes.len - offset);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}

pub fn main() !void {
    var request: Request = undefined;
    while (readExact(std.mem.asBytes(&request))) {
        var buffer: [64]u8 = undefined;
        const bytes = try reference(request, &buffer) orelse "";
        const length: u32 = @intCast(bytes.len);
        try writeAll(std.mem.asBytes(&length));
        try writeAll(bytes);
    }
}
"""


def corpus():
    geometries = [
        (8, 4, 8, 4, 2, 3, 8, 16, 1),
        (3, 2, 8, 4, 1, 1, 7, 13, 2),
        (20, 5, 16, 3, 0, 0, 9, 18, 1),
        (1, 1, 1, 1, 3, 4, 1, 1, 3),
    ]
    for geometry in geometries:
        columns, rows, width, height, origin_x, origin_y, cell_width, cell_height, scale = geometry
        left, top = origin_x * cell_width, origin_y * cell_height
        right, bottom = left + width * cell_width, top + height * cell_height
        positions = [(0, 0), (left, top), (left + cell_width // 2, top + cell_height // 2), (right - 1, bottom - 1), (right + cell_width, bottom + cell_height), (max(0, left - 1), top), (left, max(0, top - 1))]
        for tracking, sgr, pixels, phase, button, modifier, position in itertools.product(range(5), range(2), range(2), range(4), range(4), range(8), positions):
            yield tracking, sgr, pixels, phase, button, modifier << 2, *geometry, *position
    randomizer = random.Random(0x4348494C44)
    for _ in range(10000):
        geometry = (randomizer.randrange(65), randomizer.randrange(65), randomizer.randrange(65), randomizer.randrange(65), randomizer.randrange(33), randomizer.randrange(33), randomizer.randrange(1, 33), randomizer.randrange(1, 33), randomizer.randrange(1, 5))
        yield randomizer.randrange(5), randomizer.randrange(2), randomizer.randrange(2), randomizer.randrange(4), randomizer.randrange(4), randomizer.randrange(8) << 2, *geometry, randomizer.randrange(4096), randomizer.randrange(4096)


def results(output, count):
    offset = 0
    for _ in range(count):
        length = length_format.unpack_from(output, offset)[0]
        offset += length_format.size
        yield output[offset:offset + length]
        offset += length
    if offset != len(output):
        raise SystemExit("Unexpected trailing probe output")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    records = list(corpus())
    requests = b"".join(request_format.pack(*record) for record in records)
    source = (root / "src/gui/input/PointerCapture.zig").read_text()
    start = source.index("    var content = self.content;")
    projection = source[start:source.index("    const plan = data.tab_layout.paneMousePlan", start)].replace("return;", "return null;")
    source = (root / "src/client/input/pane_mouse_inputs.zig").read_text()
    start = source.index("pub fn encodeReport(")
    encoder = source[start:source.index("\n}", start) + len("\n}")]
    with tempfile.TemporaryDirectory(prefix="telar-child-mouse-") as directory:
        temporary = Path(directory)
        cpp, zig = temporary / "probe.cpp", temporary / "probe.zig"
        cpp.write_text(cpp_probe)
        zig.write_text(zig_probe.replace("RETAINED_PROJECTION", projection) + encoder)
        includes = [root / "services/gui-cpp", root / "services/runtime-cpp", root / "dlls/telar-client/include"]
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", *[flag for path in includes for flag in ("-I", str(path))], str(cpp), "-o", str(temporary / "cpp")], check=True)
        modules = ["--dep", "model", "--dep", "telar-core", "--dep", "cellgrid", "--dep", "keyinput", f"-Mroot={zig}"]
        modules += ["--dep", "telar-core", "--dep", "cellgrid", "--dep", "keyinput", "--dep", "urlscan", f"-Mmodel={root / 'src/model/model.zig'}"]
        modules += ["--dep", "cellgrid", "--dep", "keyinput", f"-Mtelar-core={root / 'src/core/core.zig'}"]
        modules += ["--dep", "cellgrid", f"-Mkeyinput={root / 'lib/keyinput/root.zig'}", f"-Mcellgrid={root / 'lib/cellgrid/root.zig'}", f"-Murlscan={root / 'lib/urlscan/root.zig'}"]
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseSafe", "-lc", *modules, f"-femit-bin={temporary / 'zig'}"], check=True)
        actual = subprocess.run([str(temporary / "cpp")], input=requests, stdout=subprocess.PIPE, check=True).stdout
        expected = subprocess.run([str(temporary / "zig")], input=requests, stdout=subprocess.PIPE, check=True).stdout
    for index, (cpp_result, zig_result) in enumerate(zip(results(actual, len(records)), results(expected, len(records)), strict=True)):
        if cpp_result != zig_result:
            raise SystemExit(f"Mismatch at {index}: request {records[index]!r}\nC++ {cpp_result!r}\nZig {zig_result!r}")
    print(f"Matched {len(records):,} child mouse projections byte-for-byte against original retained clamping, tracking policy and SGR encoder")


if __name__ == "__main__":
    main()
