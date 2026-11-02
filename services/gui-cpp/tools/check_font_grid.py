import argparse
import itertools
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile


request_format = struct.Struct("<3q4f2I")
record_format = struct.Struct("<Ii3If")

cpp_probe = r'''
#include "terminal/font_grid.hpp"
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace telar::gui;
struct Request { std::int64_t ascender, height, advance; float size, line_height, spacing, scale; std::uint32_t kind, reserved; };
struct Record { std::uint32_t state = 0; std::int32_t ascender = 0; std::uint32_t height = 0, width = 0, pixels = 0; float baseline = 0; };
static_assert(sizeof(Request) == 48);
static_assert(sizeof(Record) == 24);
Record compute(const Request &request) {
  const auto width = std::max(1, FontMetrics::roundFixed(request.advance));
  if (width > std::numeric_limits<std::uint16_t>::max()) throw std::out_of_range{"advance"};
  const FontMetrics metrics{.ascender = FontMetrics::roundFixed(request.ascender), .line_height = std::uint32_t(std::max(1, FontMetrics::roundFixed(request.height))), .maximum_advance = std::uint16_t(width)};
  if (request.kind == 0) return {.state = 1, .ascender = metrics.ascender, .height = metrics.line_height, .width = metrics.maximum_advance};
  FontConfiguration font;
  font.size = request.size;
  font.line_height = request.line_height;
  font.letter_spacing = request.spacing;
  const auto grid = FontGrid::resolve(metrics, font, request.scale);
  return {.state = 1, .height = grid.height, .width = grid.width, .pixels = grid.pixel_height, .baseline = grid.baseline};
}
int main() {
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    Record result;
    try { result = compute(request); } catch (const std::exception &) { result.state = 2; }
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
  }
}
'''

freetype_probe = r'''
pub const c = struct {
    pub const FT_SizeRec = extern struct { metrics: extern struct { ascender: i64, height: i64, max_advance: i64 } };
    pub const FT_Size = *FT_SizeRec;
};
'''

zig_probe = r'''
const std = @import("std");
const FontSize = @import("font_size");
const GuiFont = @import("gui_font");
const ft = @import("freetype").c;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct { ascender: i64, height: i64, advance: i64, size: f32, line_height: f32, spacing: f32, scale: f32, kind: u32, reserved: u32 };
const Record = extern struct { state: u32 = 0, ascender: i32 = 0, height: u32 = 0, width: u32 = 0, pixels: u32 = 0, baseline: f32 = 0 };
const Metrics = struct { cell_width: u16 = 0, cell_height: u16 = 0, pixel_height: u16 = 0, baseline: f32 = 0 };
const Model = struct { config: struct { font: GuiFont }, metrics: Metrics = .{} };
const Replacement = struct {
    size: FontSize,
    fn lineHeight(self: @This(), _: u16) !u32 { return self.size.lineHeight(); }
    fn cellWidth(self: @This(), _: u16) !u16 { return self.size.maxAdvance(); }
    fn ascender(self: @This(), _: u16) !i32 { return self.size.ascender(); }
};
__SCALE_LIMIT__
fn geometry(request: Request, replacement: Replacement) !Record {
    const viewport = .{ .scale = request.scale };
    if (!std.math.isFinite(viewport.scale) or viewport.scale <= 0 or viewport.scale > max_display_scale) return error.InvalidDisplayScale;
    var model: Model = .{ .config = .{ .font = .{ .size = request.size, .line_height = request.line_height, .letter_spacing = request.spacing } } };
    const self = &model;
    const pixel_height: u16 = @intFromFloat(@round(self.config.font.scaledSize(viewport.scale)));
    if (pixel_height == 0) return error.InvalidPixelHeight;
    __MEASURE__
    return .{ .state = 1, .height = self.metrics.cell_height, .width = self.metrics.cell_width, .pixels = self.metrics.pixel_height, .baseline = self.metrics.baseline };
}
fn compute(request: Request) !Record {
    var raw: ft.FT_SizeRec = .{ .metrics = .{ .ascender = request.ascender, .height = request.height, .max_advance = request.advance } };
    const size: FontSize = .{ .pixel_height = 1, .handle = &raw };
    if (request.kind == 0) return .{ .state = 1, .ascender = size.ascender(), .height = size.lineHeight(), .width = size.maxAdvance() };
    return geometry(request, .{ .size = size });
}
pub fn main() void {
    var request: Request = undefined;
    while (true) {
        const input = std.mem.asBytes(&request);
        var offset: usize = 0;
        while (offset < input.len) {
            const count = read(0, input[offset..].ptr, input.len - offset);
            if (count <= 0) return;
            offset += @intCast(count);
        }
        var record = compute(request) catch Record{ .state = 2 };
        const output = std.mem.asBytes(&record);
        offset = 0;
        while (offset < output.len) {
            const count = write(1, output[offset..].ptr, output.len - offset);
            if (count <= 0) std.process.exit(2);
            offset += @intCast(count);
        }
    }
}
'''


def requests():
    for value in range(-65536, 65537):
        yield request_format.pack(value, value, value, 15, 1, 0, 1, 0, 0)
    for raw, scale, size, line_height, spacing in itertools.product(
        ((0, 0, 0), (15 * 64, 20 * 64, 9 * 64), (31 * 64, 40 * 64, 18 * 64), (19 * 64 + 32, 27 * 64 - 32, 17 * 64 + 32), (65535 * 64, 65535 * 64, 65535 * 64)),
        (0, 0.01, 0.75, 1, 1.25, 1.5, 2, 4, 8, 8.25),
        (6, 7.5, 15, 18.5, 48, 96),
        (0.75, 1, 1.2, 1.5, 3),
        (-5, -0.5, 0, 0.5, 1.25, 20),
    ):
        yield request_format.pack(*raw, size, line_height, spacing, scale, 1, 0)
    randomizer = random.Random(0xF017)
    for _ in range(50000):
        ascender = randomizer.randrange(-(1 << 31) + 1, (1 << 31) - 1) * 64 + randomizer.randrange(-31, 32)
        yield request_format.pack(ascender, randomizer.randrange(-65536, 65536), randomizer.randrange(-65536, 65535 * 64), 15, 1, 0, 1, 0, 0)
    for _ in range(50000):
        raw = (randomizer.randrange(-300, 400) * 64, randomizer.randrange(1, 300) * 64, randomizer.randrange(1, 200) * 64)
        yield request_format.pack(*raw, randomizer.uniform(6, 96), randomizer.uniform(0.75, 3), randomizer.uniform(-5, 20), randomizer.uniform(0.01, 8), 1, 0)


def reference_source(root):
    source = (root / "src/gui/render/Renderer.zig").read_text()
    start = source.index("        const natural_height: f32 = @floatFromInt(try replacement.lineHeight(pixel_height));")
    end = source.index("        if (self.atlas)", start)
    measured = source[start:end]
    if measured.count("self.metrics =") != 1 or "return error.InvalidFontSpacing;" not in measured:
        raise RuntimeError("Renderer.measure no longer matches the metric extraction contract")
    limit = re.search(r"pub const max_display_scale: f32 = [^;]+;", source).group(0)
    return zig_probe.replace("__MEASURE__", measured).replace("__SCALE_LIMIT__", limit)


def main():
    parser = argparse.ArgumentParser(description="Compare font metric arithmetic with the original GUI")
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    records = list(requests())
    payload = b"".join(records)
    with tempfile.TemporaryDirectory(prefix="telar-font-grid-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(reference_source(root))
        (work / "freetype.zig").write_text(freetype_probe)
        subprocess.run([options.compiler, "-std=c++23", "-O2", "-ffp-contract=off", "-I", str(root / "services/gui-cpp"), "-I", str(root / "services/runtime-cpp"), "-I", str(root / "dlls/telar-client/include"), str(work / "probe.cpp"), "-o", str(work / "cpp")], check=True)
        subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "font_size", "--dep", "gui_font", "--dep", "freetype", f"-Mroot={work / 'probe.zig'}", "--dep", "freetype", f"-Mfont_size={root / 'src/gui/text/FontSize.zig'}", f"-Mgui_font={root / 'src/client/config/GuiFont.zig'}", f"-Mfreetype={work / 'freetype.zig'}", f"-femit-bin={work / 'zig'}"], check=True)
        expected = subprocess.run([str(work / "zig")], input=payload, capture_output=True, check=True).stdout
        actual = subprocess.run([str(work / "cpp")], input=payload, capture_output=True, check=True).stdout
        if actual != expected:
            for index in range(min(len(actual), len(expected)) // record_format.size):
                offset = index * record_format.size
                if actual[offset:offset + record_format.size] != expected[offset:offset + record_format.size]:
                    raise RuntimeError(f"Font metric mismatch at {index}: input={request_format.unpack(records[index])}, C++={record_format.unpack_from(actual, offset)}, Zig={record_format.unpack_from(expected, offset)}")
            raise RuntimeError("Font metric probe output lengths differ")
    print(f"Matched {len(records):,} font metric records byte-for-byte against original FontSize and Renderer.measure arithmetic")


if __name__ == "__main__":
    main()
