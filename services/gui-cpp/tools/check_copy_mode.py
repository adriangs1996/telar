import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<12I")
result_format = struct.Struct("<26I")

cpp_probe = r"""
#include "terminal/copy_navigation.hpp"
#include "core/unicode_scalar.hpp"
#include <array>
#include <bit>
#include <cstdint>
#include <iostream>
#include <span>

using namespace telar::gui;

struct Request {
  std::uint32_t operation, code, scalar, modifiers, x, y, offset, total, previous, delta, granularity, direction;
};

struct Result {
  std::uint32_t cursor_x, cursor_y, anchor_present, anchor_x, anchor_y, linewise;
  std::uint32_t entry, viewport, direction, match_index, match_count;
  std::uint32_t pointer_present, start_x, start_y, end_x, end_y, granularity, columns, rows;
  std::uint32_t handled, exit, copy, search, open_link, selected_first, selected_last;
};

int main() {
  constexpr std::uint16_t columns = 10, rows = 4;
  constexpr std::string_view text = "  foo/bar " "baz   end " "          " "last row  ";
  std::array<CellValue, columns * rows> cells{};
  for (std::size_t index = 0; index < cells.size(); ++index) { cells[index].text[0] = text[index]; }
  const auto ideograph = cells.size() - 2;
  const auto encoded = Utf8Scalar::encode(U'中');
  std::copy(encoded.bytes.begin(), encoded.bytes.begin() + encoded.length, cells[ideograph].text.begin());
  cells[ideograph].length = encoded.length;
  cells[ideograph].width = telar::CellWidth::wide;
  cells.back().length = 0;
  cells.back().width = telar::CellWidth::continuation;
  CopyState state;
  std::array<telar::PaneMatch, 2> matches{};
  std::size_t match_count = 0;
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    const CopyGrid grid{cells, columns, rows, {.total_rows = request.total, .offset = request.offset}};
    CopyEffect effect;
    switch (request.operation) {
    case 0:
      state = CopyState{.pane_id = 1, .cursor = {static_cast<std::uint16_t>(request.x), request.y}, .entry_offset = request.offset, .viewport_offset = request.offset};
      match_count = 0;
      break;
    case 1:
      effect = CopyNavigation::apply(state, {.code = static_cast<KeyChord::Key>(request.code), .codepoint = request.scalar, .modifiers = request.modifiers}, grid, std::span{matches}.first(match_count));
      break;
    case 2: state.vertical(std::bit_cast<std::int32_t>(request.delta), grid); break;
    case 3: state.onFrame(request.previous, grid.scroll); break;
    case 4:
      matches = {telar::PaneMatch{2, request.offset, 3}, telar::PaneMatch{0, request.offset + 1, 3}};
      match_count = request.direction == 2 ? 0 : matches.size();
      state.applyMatches(std::span{matches}.first(match_count), grid);
      break;
    case 5:
      state.cursor = {.x = static_cast<std::uint16_t>(request.x), .y = request.offset + request.y};
      state.beginPointer(static_cast<CopyGranularity>(request.granularity), grid);
      break;
    case 6: state.movePointer({static_cast<std::uint16_t>(request.x), request.offset + request.y}, grid); break;
    default: return 1;
    }
    const auto pointer = state.pointer.value_or(CopyPointer{});
    const auto anchor = state.anchor.value_or(CopyPoint{});
    const auto selection = state.selection(grid);
    const Result result{
      state.cursor.x, state.cursor.y, state.anchor.has_value(), anchor.x, anchor.y, state.linewise,
      state.entry_offset, state.viewport_offset, static_cast<std::uint32_t>(state.search_direction), state.match_index, static_cast<std::uint32_t>(match_count),
      state.pointer.has_value(), pointer.start.x, pointer.start.y, pointer.end.x, pointer.end.y, static_cast<std::uint32_t>(pointer.granularity), pointer.columns, pointer.rows,
      effect.handled, effect.exit, effect.copy, effect.search ? static_cast<std::uint32_t>(*effect.search) + 1 : 0, effect.open_link,
      static_cast<std::uint32_t>(selection.anchor + 1), static_cast<std::uint32_t>(selection.head + 1),
    };
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
  }
}
"""

zig_probe = r"""
const std = @import("std");
const model = @import("model");
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const keyinput = @import("keyinput");
const CopyEffect = @typeInfo(@TypeOf(model.copy_mode.applyKey)).@"fn".return_type.?;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;

const Request = extern struct {
    operation: u32, code: u32, scalar: u32, modifiers: u32, x: u32, y: u32,
    offset: u32, total: u32, previous: u32, delta: u32, granularity: u32, direction: u32,
};

const Result = extern struct {
    cursor_x: u32, cursor_y: u32, anchor_present: u32, anchor_x: u32, anchor_y: u32, linewise: u32,
    entry: u32, viewport: u32, direction: u32, match_index: u32, match_count: u32,
    pointer_present: u32, start_x: u32, start_y: u32, end_x: u32, end_y: u32, granularity: u32, columns: u32, rows: u32,
    handled: u32, exit: u32, copy: u32, search: u32, open_link: u32, selected_first: u32, selected_last: u32,
};

fn key(request: Request) !keyinput.Key {
    var bytes: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(@intCast(request.scalar), &bytes);
    const code: keyinput.Key.Code = switch (request.code) {
        0 => .{ .char = keyinput.Char.init(bytes[0..length]) },
        1 => .up, 2 => .down, 3 => .left, 4 => .right, 5 => .home, 6 => .end,
        7 => .delete, 8 => .page_up, 9 => .page_down, 10 => .enter, 11 => .escape,
        12 => .backspace, 13 => .tab, 14 => .back_tab,
        else => return error.InvalidKey,
    };
    return .{ .code = code, .mods = .{
        .ctrl = request.modifiers & 1 != 0, .alt = request.modifiers & 2 != 0,
        .shift = request.modifiers & 4 != 0, .super = request.modifiers & 8 != 0,
    } };
}

pub fn main() !void {
    const columns = 10;
    const rows = 4;
    const text = "  foo/bar " ++ "baz   end " ++ "          " ++ "last row  ";
    var cells: [columns * rows]cellgrid.Cell = @splat(.{});
    for (&cells, text) |*cell, byte| { cell.bytes[0] = byte; }
    const ideograph = cells.len - 2;
    cells[ideograph].len = try std.unicode.utf8Encode('中', &cells[ideograph].bytes);
    cells[ideograph].width = 2;
    cells[cells.len - 1].len = 0;
    cells[cells.len - 1].width = 0;
    const buffer: cellgrid.Buffer = .{ .cells = &cells, .w = columns, .h = rows, .gpa = std.heap.page_allocator, .clip = .{ .w = columns, .h = rows } };
    var state = model.State.init(@enumFromInt(1), .{ .x = 0, .y = 0 }, 0);
    while (true) {
        var request: Request = undefined;
        const destination = std.mem.asBytes(&request);
        var received: usize = 0;
        while (received < destination.len) {
            const amount = read(0, destination[received..].ptr, destination.len - received);
            if (amount == 0 and received == 0) { return; }
            if (amount <= 0) { return error.ShortRead; }
            received += @intCast(amount);
        }
        const scroll: core.Scroll = .{ .total_rows = request.total, .offset = request.offset };
        const screen: @typeInfo(@TypeOf(model.copy_mode.applyKey)).@"fn".params[2].type.? = .{ .buffer = &buffer, .scroll = scroll };
        var effect: CopyEffect = .{};
        switch (request.operation) {
            0 => state = model.State.init(@enumFromInt(1), .{ .x = @intCast(request.x), .y = request.y }, request.offset),
            1 => effect = model.copy_mode.applyKey(&state, try key(request), screen),
            2 => state.vertical(@bitCast(request.delta), .{ .scroll = scroll, .rows = rows }),
            3 => model.copy_mode.onFrame(&state, request.previous, scroll),
            4 => {
                const matches = [_]core.SearchMatch{ .{ .x = 2, .y = request.offset, .len = 3 }, .{ .x = 0, .y = request.offset + 1, .len = 3 } };
                state.applyMatches(if (request.direction == 2) &.{} else &matches, .{ .scroll = scroll, .rows = rows });
            },
            5 => {
                state.cursor = .{ .x = @intCast(request.x), .y = request.offset + request.y };
                state.beginPointer(@enumFromInt(request.granularity), screen);
            },
            6 => state.movePointer(.{ .position = .{ .x = @intCast(request.x), .y = @intCast(request.y) } }, screen),
            else => return error.InvalidOperation,
        }
        const anchor: @TypeOf(state.cursor) = state.anchor orelse .{ .x = 0, .y = 0 };
        var first: u32 = 0;
        var last: u32 = 0;
        for (0..columns * rows) |index| {
            if (state.view().selected(@intCast(index % columns), request.offset + @as(u32, @intCast(index / columns)))) {
                if (first == 0) { first = @intCast(index + 1); }
                last = @intCast(index + 1);
            }
        }
        const result: Result = .{
            .cursor_x = state.cursor.x, .cursor_y = state.cursor.y, .anchor_present = @intFromBool(state.anchor != null), .anchor_x = anchor.x, .anchor_y = anchor.y, .linewise = @intFromBool(state.linewise),
            .entry = state.entry_offset, .viewport = state.viewport_offset, .direction = @intFromEnum(state.search_direction), .match_index = state.match_index, .match_count = state.match_count,
            .pointer_present = @intFromBool(state.pointer != null), .start_x = if (state.pointer) |pointer| pointer.start.x else 0, .start_y = if (state.pointer) |pointer| pointer.start.y else 0,
            .end_x = if (state.pointer) |pointer| pointer.end.x else 0, .end_y = if (state.pointer) |pointer| pointer.end.y else 0,
            .granularity = if (state.pointer) |pointer| @intFromEnum(pointer.granularity) else 0, .columns = if (state.pointer) |pointer| pointer.cols else 0, .rows = if (state.pointer) |pointer| pointer.rows else 0,
            .handled = @intFromBool(effect.handled), .exit = @intFromBool(effect.exit), .copy = @intFromBool(effect.copy), .search = if (effect.search) |direction| @as(u32, @intFromEnum(direction)) + 1 else 0,
            .open_link = @intFromBool(effect.open_link), .selected_first = first, .selected_last = last,
        };
        const output = std.mem.asBytes(&result);
        var sent: usize = 0;
        while (sent < output.len) {
            const amount = write(1, output[sent..].ptr, output.len - sent);
            if (amount <= 0) { return error.ShortWrite; }
            sent += @intCast(amount);
        }
    }
}
"""


def record(operation=0, code=0, scalar=97, modifiers=0, x=0, y=0, offset=0, total=8, previous=0, delta=0, granularity=0, direction=0):
    return (operation, code, scalar, modifiers, x, y, offset, total, previous, delta & 0xffffffff, granularity, direction)


def corpus(random_cases):
    keys = [(0, scalar, modifiers) for scalar, modifiers in itertools.product(range(128), (0, 1, 2, 4))]
    keys.extend((code, 97, 0) for code in range(1, 15))
    records = []
    for (code, scalar, modifiers), x, y in itertools.product(keys, (0, 3, 9), (0, 3, 7)):
        records.extend((record(x=x, y=y), record(1, code, scalar, modifiers)))
    commands = "hjkl0^$web{}gG/?nNovVyq "
    for first, second in itertools.product(commands, repeat=2):
        records.extend((record(x=3, y=1), record(1, scalar=ord(first)), record(4), record(1, scalar=ord(second))))
    for x, y, granularity in itertools.product(range(10), range(4), range(3)):
        records.extend((record(x=x, y=y), record(5, granularity=granularity), record(6, x=9-x, y=3-y)))
    for offset, x, y, granularity in itertools.product((0, 4, 96), (0, 9), (0, 3), range(3)):
        total = offset + 4
        records.extend((record(x=x, y=offset+y, offset=offset, total=total), record(5, x=x, y=y, offset=offset, total=total, granularity=granularity), record(3, offset=max(0, offset-2), total=max(4, total-2), previous=offset)))
    generator = random.Random(0x74656c6172)
    records.append(record())
    for _ in range(random_cases):
        operation = generator.choice([1] * 20 + list(range(7)))
        code, scalar, modifiers = generator.choice(keys)
        records.append(record(operation, code, scalar, modifiers, generator.randrange(10), generator.randrange(4), delta=generator.choice((-4, -1, 0, 1, 4)), granularity=generator.randrange(3), direction=generator.randrange(3)))
    return records


def main():
    parser = argparse.ArgumentParser(description="Compare copy navigation against the original Zig model")
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--random-cases", type=int, default=20000)
    arguments = parser.parse_args()
    if arguments.random_cases < 0:
        parser.error("--random-cases must be nonnegative")
    service = Path(__file__).resolve().parents[1]
    repository = service.parents[1]
    records = corpus(arguments.random_cases)
    request = b"".join(request_format.pack(*entry) for entry in records)
    with tempfile.TemporaryDirectory(prefix="telar-copy-mode-") as directory:
        temporary = Path(directory)
        cpp_source, zig_source = temporary / "probe.cpp", temporary / "probe.zig"
        cpp_binary, zig_binary = temporary / "cpp_probe", temporary / "zig_probe"
        cpp_source.write_text(cpp_probe)
        zig_source.write_text(zig_probe)
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", f"-I{service}", f"-I{repository / 'services/runtime-cpp'}", f"-I{repository / 'services/desktop-mode'}", str(cpp_source), "-o", str(cpp_binary)], check=True)
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "model", "--dep", "cellgrid", "--dep", "telar-core", "--dep", "keyinput", f"-Mroot={zig_source}", "--dep", "telar-core", "--dep", "cellgrid", "--dep", "keyinput", f"-Mmodel={repository / 'src/model/model.zig'}", "--dep", "cellgrid", "--dep", "keyinput", f"-Mtelar-core={repository / 'src/core/core.zig'}", f"-Mkeyinput={repository / 'lib/keyinput/root.zig'}", f"-Mcellgrid={repository / 'lib/cellgrid/root.zig'}", f"-femit-bin={zig_binary}"], check=True)
        reference = subprocess.run([str(zig_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
        candidate = subprocess.run([str(cpp_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
    if len(reference) != len(records) * result_format.size or len(candidate) != len(reference):
        raise SystemExit("Unexpected probe result length")
    for index, entry in enumerate(records):
        offset = index * result_format.size
        expected = reference[offset:offset + result_format.size]
        actual = candidate[offset:offset + result_format.size]
        if expected != actual:
            raise SystemExit(f"Record {index}, request {entry}: Zig {result_format.unpack(expected)}, C++ {result_format.unpack(actual)}")
    print(f"Matched {len(records)} copy-mode transitions byte-for-byte against src/model/input/copy_mode.zig and State.zig")


if __name__ == "__main__":
    main()
