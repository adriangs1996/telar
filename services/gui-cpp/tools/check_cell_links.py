import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<6I")
result_format = struct.Struct("<7I")
cell_format = struct.Struct("<BB16s")

cpp_probe = r"""
#include "links/cell_links.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

using namespace telar::gui;
struct Request { std::uint32_t columns, rows, x, y, offset, flags; };
struct Result { std::uint32_t scheme = 0, start_x = 0, start_y = 0, end_x = 0, end_y = 0, length = 0, valid = 0; };
int main() {
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    if (request.columns == 0 || request.columns > 65535 || request.rows == 0 || request.rows > 65535 || request.columns * request.rows > 130359) { return 1; }
    std::vector<telar::Byte> flags(request.rows);
    if (!std::cin.read(reinterpret_cast<char *>(flags.data()), flags.size())) { return 1; }
    std::vector<CellValue> cells(request.columns * request.rows);
    for (auto &cell : cells) {
      std::array<char, 18> bytes{};
      if (!std::cin.read(bytes.data(), bytes.size())) { return 1; }
      cell.width = static_cast<telar::CellWidth>(bytes[0]); cell.length = bytes[1];
      std::copy_n(bytes.begin() + 2, cell.text.size(), cell.text.begin());
    }
    const LinkGrid grid{.cells = cells, .columns = static_cast<std::uint16_t>(request.columns), .rows = static_cast<std::uint16_t>(request.rows), .scroll = {.total_rows = request.offset + request.rows, .offset = request.offset}, .row_flags = request.flags ? std::span<const telar::Byte>{flags} : std::span<const telar::Byte>{}};
    const auto found = CellLinks::match(grid, {.x = static_cast<std::uint16_t>(request.x), .y = request.y});
    Result result;
    if (found) {
      result.scheme = static_cast<std::uint32_t>(found->target.scheme()) + 1;
      result.start_x = found->start.x; result.start_y = found->start.y; result.end_x = found->end.x; result.end_y = found->end.y;
      result.length = found->target.text().size(); result.valid = 1;
    }
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
    if (found) { std::cout.write(found->target.text().data(), found->target.text().size()); }
  }
}
"""

zig_probe = r"""
const std = @import("std");
const urlscan = @import("urlscan");
const cellgrid = @import("cellgrid");
const data = @import("model");
const core = @import("telar-core");
const LinkGrid = @import("link_grid");
const LinkMatch = data.LinkMatch;
const Position = @FieldType(LinkMatch, "start");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct { columns: u32, rows: u32, x: u32, y: u32, offset: u32, flags: u32 };
const Result = extern struct { scheme: u32 = 0, start_x: u32 = 0, start_y: u32 = 0, end_x: u32 = 0, end_y: u32 = 0, length: u32 = 0, valid: u32 = 0 };
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
        var buffer = try cellgrid.Buffer.init(std.heap.c_allocator, @intCast(request.columns), @intCast(request.rows));
        defer buffer.deinit();
        const flags = try std.heap.c_allocator.alloc(core.TextRowFlags, request.rows);
        defer std.heap.c_allocator.free(flags);
        if (!readExact(std.mem.sliceAsBytes(flags))) return error.InvalidFlags;
        for (buffer.cells) |*cell| {
            var bytes: [18]u8 = undefined;
            if (!readExact(&bytes)) return error.InvalidCell;
            cell.width = bytes[0]; cell.len = bytes[1];
            @memcpy(&cell.bytes, bytes[2..]);
        }
        const grid: LinkGrid = .{ .buffer = &buffer, .scroll = .{ .total_rows = request.offset + request.rows, .offset = request.offset }, .rows = if (request.flags != 0) flags else &.{} };
        const found = matchGrid(grid, .{ .x = @intCast(request.x), .y = request.y });
        var result: Result = .{};
        if (found) |match| {
            result.scheme = @intFromEnum(match.target.scheme) + 1;
            result.start_x = match.start.x; result.start_y = match.start.y; result.end_x = match.end.x; result.end_y = match.end.y;
            result.length = match.target.len; result.valid = 1;
        }
        try writeAll(std.mem.asBytes(&result));
        if (found) |match| { try writeAll(match.target.uri()); }
    }
}
"""


def cell(text=b" ", width=1):
    return cell_format.pack(width, len(text), text)


def cells_for(text, columns, rows):
    cells = []
    for character in text:
        width = 2 if character == "中" else 1
        cells.append(cell(character.encode(), width))
        if width == 2:
            cells.append(cell(b"", 0))
    count = columns * rows
    return b"".join((cells + [cell()] * count)[:count])


def corpus():
    columns, rows = 12, 4
    text = "see [中doc](https://example.com/a(b)) src/a.cpp:12"
    cells = cells_for(text, columns, rows)
    positions = [(0, 0), (5, 0), (10, 0), (0, 1), (11, 1), (5, 2), (3, 3), (11, 3)]
    for flags in itertools.product(range(8), repeat=rows):
        for x, y in positions:
            yield columns, rows, x, y + 5, 5, 1, bytes(flags), cells
    examples = ["https://example.com/a(b)", "[中docs](https://x)", "src/a.cpp:12", "http://x/a/b/", "(https://x).", "http://x/中", "", "mailto:a@x", "[a](http://x)"]
    randomizer = random.Random(0x43454C4C)
    for _ in range(12000):
        columns = randomizer.choice([1, 4, 8, 12, 20, 40, 80])
        rows = randomizer.randrange(1, 7)
        text = (" " * randomizer.randrange(12)) + randomizer.choice(examples) + " tail " + randomizer.choice(examples)
        cells = cells_for(text, columns, rows)
        flags = bytes(randomizer.choices(range(8), k=rows))
        offset = randomizer.randrange(64)
        yield columns, rows, randomizer.randrange(columns + 1), offset + randomizer.randrange(rows + 1), offset, randomizer.randrange(2), flags, cells
    for length in [4095, 4096, 4097, 4612, 9256, 20000]:
        cells = cells_for("https://x/" + ("a" * length), length, 1)
        for x in [0, length // 2, length - 1, length]:
            yield length, 1, x, 0, 0, 0, bytes(1), cells
        empty_cells = (cell(b"") * (length - 1)) + cell(b"x")
        yield length, 1, length - 1, 0, 0, 0, bytes(1), empty_cells


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    records = list(corpus())
    data = b"".join(request_format.pack(*entry[:6]) + entry[6] + entry[7] for entry in records)
    source = (root / "src/model/links/cells.zig").read_text()
    constants = source[source.index("const link_span_bytes ="):source.index("/// Extracts the textual")]
    functions = source[source.index("fn matchGrid("):]
    with tempfile.TemporaryDirectory(prefix="telar-cell-links-") as directory:
        temporary = Path(directory)
        cpp = temporary / "probe.cpp"
        zig = temporary / "probe.zig"
        grid_module = temporary / "link_grid.zig"
        cpp.write_text(cpp_probe)
        zig.write_text(zig_probe + constants + functions)
        grid_source = (root / "src/model/links/LinkGrid.zig").read_text()
        grid_module.write_text(grid_source.replace('@import("Position.zig")', '@FieldType(@import("model").LinkMatch, "start")'))
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", "-I", str(root / "services/gui-cpp"), "-I", str(root / "dlls/telar-client/include"), "-I", str(root / "dlls/telar-base/include"), "-I", str(root / "dlls/telar-lua/include"), "-I", str(root / "dlls/telar-platform/include"), "-I", str(root / "dlls/telar-plugins/include"), "-I", str(root / "dlls/telar-config/include"), str(cpp), "-o", str(temporary / "cpp")], check=True)
        modules = ["--dep", "model", "--dep", "cellgrid", "--dep", "telar-core", "--dep", "urlscan", "--dep", "link_grid", f"-Mroot={zig}"]
        modules += ["--dep", "telar-core", "--dep", "cellgrid", "--dep", "keyinput", "--dep", "urlscan", f"-Mmodel={root / 'src/model/model.zig'}"]
        modules += ["--dep", "cellgrid", "--dep", "keyinput", f"-Mtelar-core={root / 'src/core/core.zig'}"]
        modules += ["--dep", "cellgrid", "--dep", "telar-core", "--dep", "model", f"-Mlink_grid={grid_module}"]
        modules += [f"-Mkeyinput={root / 'lib/keyinput/root.zig'}", f"-Mcellgrid={root / 'lib/cellgrid/root.zig'}", f"-Murlscan={root / 'lib/urlscan/root.zig'}"]
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", *modules, f"-femit-bin={temporary / 'zig'}"], check=True)
        actual = subprocess.run([str(temporary / "cpp")], input=data, stdout=subprocess.PIPE, check=True).stdout
        expected = subprocess.run([str(temporary / "zig")], input=data, stdout=subprocess.PIPE, check=True).stdout
    expected_offset = actual_offset = 0
    for index, request in enumerate(records):
        expected_header = result_format.unpack_from(expected, expected_offset)
        actual_header = result_format.unpack_from(actual, actual_offset)
        expected_record = expected[expected_offset:expected_offset + result_format.size + expected_header[5]]
        actual_record = actual[actual_offset:actual_offset + result_format.size + actual_header[5]]
        if expected_record != actual_record:
            raise SystemExit(f"Mismatch at {index}: dimensions/point/flags {request[:7]!r}\nC++ {actual_header} {actual_record[result_format.size:]!r}\nZig {expected_header} {expected_record[result_format.size:]!r}")
        expected_offset += len(expected_record)
        actual_offset += len(actual_record)
    if expected_offset != len(expected) or actual_offset != len(actual):
        raise SystemExit("Unexpected trailing probe output")
    print(f"Matched {len(records):,} cell link records byte-for-byte against original cells.matchGrid and LinkGrid")


if __name__ == "__main__":
    main()
