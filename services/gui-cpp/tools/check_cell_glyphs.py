import argparse
import itertools
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<II4f8sI")
header_format = struct.Struct("<IIf")
rectangle_bytes = 4 * struct.calcsize("<f")

cpp_probe = r"""
#include "terminal/glyphs/block.hpp"
#include "terminal/glyphs/box.hpp"
#include "terminal/glyphs/box_curve.hpp"
#include "terminal/glyphs/braille.hpp"
#include "terminal/glyphs/symbol.hpp"
#include <array>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <stdexcept>

using namespace telar::gui;
using namespace telar::gui::glyphs;
struct Request {
  std::uint32_t kind, codepoint;
  Rect cell;
  std::array<char, 8> text;
  std::uint32_t length;
};
struct Header {
  std::uint32_t state = 0, count = 0;
  float coverage = 1;
};
static_assert(sizeof(Request) == 36);
static_assert(sizeof(Header) == 12);
void writeHeader(Header header) {
  std::cout.write(reinterpret_cast<const char *>(&header), sizeof(header));
}
template <typename Paint>
void writeInk(const Paint &paint) {
  writeHeader({.state = 1, .count = std::uint32_t(paint.rectangles().size()), .coverage = paint.coverage()});
  for (auto rectangle : paint.rectangles()) {
    std::cout.write(reinterpret_cast<const char *>(&rectangle), sizeof(rectangle));
  }
}
int main() {
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    try {
      if (request.kind == 0 && request.codepoint >= Symbol::first_block && request.codepoint <= Symbol::last_block) {
        writeInk(Block::draw(request.cell, request.codepoint));
      } else if (request.kind == 1 && request.codepoint <= 255) {
        writeInk(Braille::draw(request.cell, std::uint8_t(request.codepoint)));
      } else if (request.kind == 2 && request.length <= request.text.size()) {
        auto parsed = Symbol::parse({request.text.data(), request.length});
        writeHeader(parsed ? Header{.state = 3 + std::uint32_t(parsed->kind), .count = parsed->codepoint} : Header{});
      } else if (request.kind == 3) {
        float thickness = 0;
        std::memcpy(&thickness, request.text.data(), sizeof(thickness));
        writeInk(Box::draw(request.codepoint, request.cell, thickness));
      } else if (request.kind == 4) {
        float thickness = 0;
        std::uint16_t width = 0, height = 0;
        std::memcpy(&thickness, request.text.data(), sizeof(thickness));
        std::memcpy(&width, request.text.data() + sizeof(thickness), sizeof(width));
        std::memcpy(&height, request.text.data() + sizeof(thickness) + sizeof(width), sizeof(height));
        const auto shape = BoxCurve::shape(request.codepoint);
        if (!shape || width > 256 || height > 256 || request.length > 259) return 2;
        std::array<std::uint8_t, 259 * 256 + 13> pixels;
        const auto count = request.length * height + 13;
        std::fill_n(pixels.begin(), count, 0xa5);
        BoxCurve{*shape, request.cell, thickness}.rasterize({.pixels = pixels, .stride = request.length, .width = width, .height = height});
        writeHeader({.state = 6, .count = count});
        std::cout.write(reinterpret_cast<const char *>(pixels.data()), count);
      } else {
        writeHeader({});
      }
    } catch (const std::invalid_argument &) {
      writeHeader({.state = 2});
    }
  }
}
"""

gfx_probe = r"""
pub const Rect = extern struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Color = struct { r: f32 = 1, g: f32 = 1, b: f32 = 1, a: f32 = 1 };
pub const QuadList = struct {
    rectangles: [21]Rect = undefined,
    count: usize = 0,
    coverage: f32 = 1,
    pub fn pushRect(self: *QuadList, rectangle: Rect, color: Color) !void {
        self.rectangles[self.count] = rectangle;
        self.count += 1;
        self.coverage = color.a;
    }
};
"""

zig_probe = r"""
const std = @import("std");
const glyphs = @import("cellglyphs");
const gfx = @import("gfx");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct { kind: u32, codepoint: u32, cell: gfx.Rect, text: [8]u8, length: u32 };
const Header = extern struct { state: u32 = 0, count: u32 = 0, coverage: f32 = 1 };
fn output(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = write(1, bytes[offset..].ptr, bytes.len - offset);
        if (written <= 0) std.process.exit(2);
        offset += @intCast(written);
    }
}
fn reference(request: Request, list: *gfx.QuadList, pixels: []u8) !Header {
    if (request.kind == 0 and request.codepoint >= 0x2580 and request.codepoint <= 0x259f) {
        const block: glyphs.BlockElement = .{ .codepoint = @intCast(request.codepoint) };
        const ink = try glyphs.BlockInk.init(request.cell, block);
        list.coverage = ink.coverage;
        try ink.paint(request.cell, .{}, list);
        return .{ .state = 1, .count = @intCast(list.count), .coverage = list.coverage };
    }
    if (request.kind == 1 and request.codepoint <= 255) {
        const braille: glyphs.Braille = .{ .dots = @intCast(request.codepoint) };
        _ = try braille.paint(request.cell, .{}, list);
        return .{ .state = 1, .count = @intCast(list.count), .coverage = list.coverage };
    }
    if (request.kind == 2 and request.length <= request.text.len) {
        const text = request.text[0..request.length];
        if (glyphs.BoxDrawing.parse(text)) |box| return .{ .state = 3, .count = box.codepoint };
        if (glyphs.BlockElement.parse(text)) |block| return .{ .state = 4, .count = block.codepoint };
        if (glyphs.Braille.parse(text)) |braille| return .{ .state = 5, .count = 0x2800 + @as(u32, braille.dots) };
    }
    if (request.kind == 3) {
        var grid = try glyphs.BoxGrid.init(request.cell, std.mem.bytesAsValue(f32, request.text[0..4]).*);
        grid.draw(.{ .codepoint = @intCast(request.codepoint) });
        const ink = try glyphs.BoxInk.init(&grid);
        try ink.paint(request.cell, .{}, list);
        return .{ .state = 1, .count = @intCast(list.count), .coverage = list.coverage };
    }
    if (request.kind == 4) {
        const grid = try glyphs.BoxGrid.init(request.cell, std.mem.bytesAsValue(f32, request.text[0..4]).*);
        const width = std.mem.bytesAsValue(u16, request.text[4..6]).*;
        const height = std.mem.bytesAsValue(u16, request.text[6..8]).*;
        const count = request.length * height + 13;
        @memset(pixels[0..count], 0xa5);
        const curve = glyphs.BoxCurve.init(grid, @intCast(request.codepoint - 0x256d));
        curve.rasterize(.{ .pixels = pixels, .stride = request.length, .width = width, .height = height });
        return .{ .state = 6, .count = count };
    }
    return .{};
}
pub fn main() void {
    var request: Request = undefined;
    var pixels: [259 * 256 + 13]u8 = undefined;
    while (true) {
        const bytes = std.mem.asBytes(&request);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const received = read(0, bytes[offset..].ptr, bytes.len - offset);
            if (received <= 0) return;
            offset += @intCast(received);
        }
        var list: gfx.QuadList = .{};
        var header = reference(request, &list, &pixels) catch Header{ .state = 2 };
        output(std.mem.asBytes(&header));
        if (header.state == 1) {
            output(std.mem.sliceAsBytes(list.rectangles[0..list.count]));
        } else if (header.state == 6) {
            output(pixels[0..header.count]);
        }
    }
}
"""


def requests():
    origins = ((0, 0), (1.25, -2.5), (-100, 200))
    extents = ((0, 0), (0.5, 0.25), (1, 3), (2, 4), (7, 15), (8, 16), (9, 17), (9.5, 17.25), (37, 71), (65535, 65535))
    for origin, extent in itertools.product(origins, extents):
        for codepoint in range(0x2580, 0x25A0):
            yield request_format.pack(0, codepoint, *origin, *extent, b"", 0)
        for dots in range(256):
            yield request_format.pack(1, dots, *origin, *extent, b"", 0)

        for thickness in (0.25, 0.3, 1, 2, 3, 8, 65535):
            for codepoint in range(0x2500, 0x2580):
                if not 0x256D <= codepoint <= 0x2573:
                    yield request_format.pack(3, codepoint, *origin, *extent, struct.pack("<f", thickness), 0)

    for cell in ((float("nan"), 0, 1, 1), (0, float("inf"), 1, 1), (0, 0, -1, 4), (0, 0, 1, 65536)):
        for kind, codepoint in ((0, 0x2580), (1, 255)):
            yield request_format.pack(kind, codepoint, *cell, b"", 0)
        yield request_format.pack(3, 0x2500, *cell, struct.pack("<f", 1), 0)
        yield request_format.pack(4, 0x256D, *cell, struct.pack("<fHH", 1, 16, 32), 16)
    for thickness in (0, -1, float("inf"), float("nan")):
        yield request_format.pack(3, 0x2500, 0, 0, 8, 16, struct.pack("<f", thickness), 0)
        yield request_format.pack(4, 0x256D, 0, 0, 8, 16, struct.pack("<fHH", thickness, 16, 32), 16)

    curve_extents = ((0.5, 0.75), (1, 3), (2, 4), (7, 15), (8, 16), (9.5, 17.25), (37, 71), (256, 256), (300, 450), (65535, 65535))
    for extent, thickness, raster, codepoint in itertools.product(curve_extents, (0.3, 1, 2, 8, 65535), ((1, 1), (8, 16), (16, 32), (33, 17)), range(0x256D, 0x2574)):
        width, height = raster
        yield request_format.pack(4, codepoint, 0, 0, *extent, struct.pack("<fHH", thickness, width, height), width + 3)
    for extent, codepoint in itertools.product((255, 256), range(0x256D, 0x2574)):
        yield request_format.pack(4, codepoint, 0, 0, extent, extent, struct.pack("<fHH", 1, extent, extent), extent + 3)

    for codepoint in range(0x110000):
        if 0xD800 <= codepoint <= 0xDFFF:
            continue
        text = chr(codepoint).encode("utf-8")
        yield request_format.pack(2, 0, 0, 0, 0, 0, text, len(text))

    randomizer = random.Random(0xCE11)
    for _ in range(20_000):
        kind = randomizer.randrange(2)
        codepoint = randomizer.randrange(0x2580, 0x25A0) if kind == 0 else randomizer.randrange(256)
        cell = (randomizer.randrange(-4000, 4001) / 4, randomizer.randrange(-4000, 4001) / 4, randomizer.randrange(0, 2001) / 4, randomizer.randrange(0, 4001) / 4)
        yield request_format.pack(kind, codepoint, *cell, b"", 0)
    for _ in range(20_000):
        codepoint = randomizer.choice([value for value in range(0x2500, 0x2580) if not 0x256D <= value <= 0x2573])
        cell = (randomizer.randrange(-4000, 4001) / 4, randomizer.randrange(-4000, 4001) / 4, randomizer.randrange(0, 2001) / 4, randomizer.randrange(0, 4001) / 4)
        thickness = randomizer.uniform(0.01, 100)
        yield request_format.pack(3, codepoint, *cell, struct.pack("<f", thickness), 0)
    for _ in range(20_000):
        length = randomizer.randrange(9)
        text = randomizer.randbytes(length)
        yield request_format.pack(2, 0, 0, 0, 0, 0, text, length)
    for _ in range(2000):
        codepoint = randomizer.randrange(0x256D, 0x2574)
        cell = (0, 0, randomizer.uniform(0.1, 256), randomizer.uniform(0.1, 256))
        width, height = randomizer.randrange(1, 65), randomizer.randrange(1, 65)
        yield request_format.pack(4, codepoint, *cell, struct.pack("<fHH", randomizer.uniform(0.01, 100), width, height), width + randomizer.randrange(4))


def records(output, count):
    offset = 0
    for _ in range(count):
        state, rectangles, _ = header_format.unpack_from(output, offset)
        length = header_format.size + (rectangles * rectangle_bytes if state == 1 else rectangles if state == 6 else 0)
        yield output[offset:offset + length]
        offset += length
    if offset != len(output):
        raise RuntimeError("Unexpected geometry probe output length")


def main():
    parser = argparse.ArgumentParser(description="Compare procedural cell glyphs with the original Zig geometry")
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    inputs = list(requests())
    payload = b"".join(inputs)
    with tempfile.TemporaryDirectory(prefix="telar-cell-glyphs-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(zig_probe)
        (work / "gfx.zig").write_text(gfx_probe)
        subprocess.run(["python3", str(root / "services/gui-cpp/tools/generate_box_edges.py"), str(root / "lib/cellglyphs/box_lines.zig"), str(work / "box_edge_table.hpp")], check=True)
        subprocess.run([options.compiler, "-std=c++23", "-O2", "-ffp-contract=off", "-I", str(root / "services/gui-cpp"), "-I", str(work), str(work / "probe.cpp"), str(root / "services/gui-cpp/terminal/glyphs/box_curve.cpp"), "-o", str(work / "cpp")], check=True)
        subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "cellglyphs", "--dep", "gfx", f"-Mroot={work / 'probe.zig'}", "--dep", "gfx", f"-Mcellglyphs={root / 'lib/cellglyphs/root.zig'}", f"-Mgfx={work / 'gfx.zig'}", f"-femit-bin={work / 'zig'}"], check=True)
        previous = subprocess.run([str(work / "zig")], input=payload, capture_output=True, check=True).stdout
        current = subprocess.run([str(work / "cpp")], input=payload, capture_output=True, check=True).stdout
        if current != previous:
            for index, (actual, expected) in enumerate(zip(records(current, len(inputs)), records(previous, len(inputs)))):
                if actual != expected:
                    raise RuntimeError(f"Geometry mismatch at record {index}: input={request_format.unpack(inputs[index])}, C++={actual.hex()}, Zig={expected.hex()}")
            raise RuntimeError("Geometry output sizes differ")
    print(f"Matched {len(inputs):,} procedural glyph records byte-for-byte against original Zig parsing, Braille, block, straight box geometry and curve masks")


if __name__ == "__main__":
    main()
