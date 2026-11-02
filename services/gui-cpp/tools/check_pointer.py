import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_fields = ("operation", "x", "y", "time_low", "time_high", "kind", "left", "authority", "dragging", "inside", "position_present", "phase", "precise", "cell_height", "delta")
request_format = struct.Struct("<14Id")
result_format = struct.Struct("<9I")

cpp_probe = r"""
#include "input/click_tracker.hpp"
#include "input/copy_pointer.hpp"
#include "input/wheel_accumulator.hpp"
#include <bit>
#include <cstdint>
#include <iostream>

using namespace telar::gui;

struct Request {
  std::uint32_t operation, x, y, time_low, time_high, kind, left, authority, dragging, inside, position_present, phase, precise, cell_height;
  double delta;
};

struct Result {
  std::uint32_t click = 0, lines = 0, outcome = 0, command = 0, x = 0, y = 0, released = 0, rows = 0, effects = 0;
};

int main() {
  ClickTracker clicks;
  WheelAccumulator wheel;
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    Result result;
    const CopyPoint point{.x = static_cast<std::uint16_t>(request.x), .y = request.y};
    if (request.operation == 0) {
      clicks = {};
      wheel.reset();
    } else if (request.operation == 1) {
      const auto now = (static_cast<std::uint64_t>(request.time_high) << 32) | request.time_low;
      result.click = static_cast<std::uint32_t>(clicks.press(point, now));
    } else if (request.operation == 2) {
      result.lines = std::bit_cast<std::uint32_t>(wheel.consume({.delta = request.delta, .cell_height = static_cast<double>(request.cell_height), .precise = request.precise != 0, .phase = static_cast<ScrollPhase>(request.phase)}));
    } else if (request.operation == 3) {
      const CopyPointerInput input{.position = point, .kind = static_cast<CopyPointerKind>(request.kind), .left_button = request.left != 0, .rows = static_cast<std::int32_t>(request.delta)};
      const CopyPointerAuthority authority{.kind = static_cast<CopyPointerAuthority::Kind>(request.authority), .dragging = request.dragging != 0, .inside = request.inside != 0, .position = request.position_present ? std::optional{point} : std::nullopt};
      const auto decision = routeCopyPointer(input, authority);
      result.outcome = static_cast<std::uint32_t>(decision.outcome);
      result.command = decision.leave ? 1 : decision.cancel ? 2 : decision.motion ? 3 : decision.vertical ? 4 : 0;
      result.effects = result.command != 0;
      if (decision.motion) {
        result.x = decision.motion->x;
        result.y = decision.motion->y;
        result.released = input.kind == CopyPointerKind::release;
      }
      if (decision.vertical) { result.rows = std::bit_cast<std::uint32_t>(*decision.vertical); }
    } else { return 1; }
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
  }
}
"""

zig_probe = r"""
const std = @import("std");
const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const ScrollEvent = @import("scroll_event");
const InputLimit = @import("input_limit").InputLimit;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;

const Request = extern struct {
    operation: u32, x: u32, y: u32, time_low: u32, time_high: u32, kind: u32, left: u32,
    authority: u32, dragging: u32, inside: u32, position_present: u32, phase: u32, precise: u32, cell_height: u32,
    delta: f64,
};

const Result = extern struct {
    click: u32 = 0, lines: u32 = 0, outcome: u32 = 0, command: u32 = 0,
    x: u32 = 0, y: u32 = 0, released: u32 = 0, rows: u32 = 0, effects: u32 = 0,
};

const Client = struct { result: Result = .{} };
const Command = union(enum) { cancel_pointer, pointer: struct { position: cellgrid.Point, release: bool }, vertical: i32 };
const copy_mode = struct {
    fn leaveCopyMode(client: *Client) !void {
        client.result.command = 1;
        client.result.effects += 1;
    }
    fn applyCopyMode(client: *Client, command: Command) !void {
        client.result.effects += 1;
        switch (command) {
            .cancel_pointer => client.result.command = 2,
            .pointer => |motion| {
                client.result.command = 3;
                client.result.x = motion.position.x;
                client.result.y = motion.position.y;
                client.result.released = @intFromBool(motion.release);
            },
            .vertical => |rows| { client.result.command = 4; client.result.rows = @bitCast(rows); },
        }
    }
};

@pointer_declarations@
@pointer_route@

const window_input = struct {
    const PointerEvent = struct { kind: keyinput.Mouse.Kind, mods: u4, x: f64, y: f64 };
    fn cancelBinding(_: *Model) void {}
};

const Pointer = struct {
    revision: u64 = 0,
    gesture_revision: u64 = 0,
    scroll_remainder: f64 = 0,
    geometry: struct { size: struct { cell_height_px: u16 = 1 } = .{} } = .{},
    fn sample(_: *Pointer, event: window_input.PointerEvent) window_input.PointerEvent { return event; }
};
const Model = struct { pointer: Pointer = .{} };
const ScrollSample = struct { geometry_revision: u64 = 0, gesture_revision: u64 = 0, event: ScrollEvent, started: bool = false, lines: i8 = 0 };
const GuiAdapter = struct {
    model: Model = .{},
    lines: i32 = 0,
    fn apply(_: *GuiAdapter, _: union(enum) { scroll: ScrollEvent }) !bool { return false; }
    fn dispatchPointer(self: *GuiAdapter, event: window_input.PointerEvent) !void {
        self.lines += if (event.kind == .scroll_up) @as(i32, -1) else 1;
    }
};

@scroll_route@

pub fn main() !void {
    var clicks: cellgrid.ClickTracker = .{};
    var gui: GuiAdapter = .{};
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
        var result: Result = .{};
        if (request.operation == 0) {
            clicks = .{};
            gui = .{};
        } else if (request.operation == 1) {
            const now = (@as(u64, request.time_high) << 32) | request.time_low;
            result.click = @intFromEnum(clicks.press(.{ .x = @intCast(request.x), .y = @intCast(request.y) }, now));
        } else if (request.operation == 2) {
            gui.model.pointer.geometry.size.cell_height_px = @intCast(request.cell_height);
            gui.lines = 0;
            var sample: ScrollSample = .{ .event = .{ .delta_y = request.delta, .precise = request.precise != 0, .phase = @enumFromInt(request.phase) } };
            while (!try dispatchScroll(&gui, &sample)) {}
            result.lines = @bitCast(gui.lines);
        } else if (request.operation == 3) {
            const kind: keyinput.Mouse.Kind = switch (request.kind) {
                0 => .press, 1 => .drag, 2 => .release,
                3 => if (request.delta < 0) .scroll_up else .scroll_down,
                4 => .move, else => return error.InvalidKind,
            };
            const position: ?cellgrid.Point = if (request.position_present != 0) .{ .x = @intCast(request.x), .y = @intCast(request.y) } else null;
            const authority: Authority = switch (request.authority) {
                0 => .unowned, 1 => .target_missing,
                2 => .{ .selection = .{ .dragging = request.dragging != 0, .position = position } },
                3 => .{ .owned = .{ .pointer_inside = request.inside != 0 } },
                else => return error.InvalidAuthority,
            };
            var client: Client = .{};
            const outcome = try route(&client, .{ .kind = kind, .left_button = request.left != 0 }, authority);
            result = client.result;
            result.outcome = @intFromEnum(outcome);
        } else { return error.InvalidOperation; }
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


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            end = index + 1
            if source[end:end + 1] == ";":
                end += 1
            return source[start:end]
    raise ValueError(f"Unterminated source declaration: {marker}")


def record(operation=0, position=(0, 0), now=0, **fields):
    values = dict.fromkeys(request_fields, 0)
    values.update(operation=operation, x=position[0], y=position[1], time_low=now & 0xffffffff, time_high=now >> 32, cell_height=1)
    if set(fields) - set(values):
        raise ValueError("Unknown request field")
    values.update(fields)
    return tuple(values[name] for name in request_fields)


def corpus(random_cases):
    records = []
    interval = 500000000
    maximum_time = (1 << 64) - 1
    for position, elapsed in itertools.product(((0, 0), (1, 0), (2, 0), (0, 1), (65535, 65535)), (0, 1, interval-1, interval, interval+1, maximum_time)):
        records.extend((record(), record(1), record(1, position, elapsed), record(1, position, elapsed), record(1, position, 0)))
    for precise, height, delta, phase in itertools.product((0, 1), (0, 1, 2, 16, 65535), (0.0, 0.25, -0.25, 0.9, 1.0, -1.0, 31.9, 32.0, -32.1, 1e300, -1e300), range(5)):
        records.extend((record(), record(2, precise=precise, cell_height=height, delta=delta, phase=phase), record(2, precise=precise, cell_height=height, delta=0.75)))
    for authority, kind, dragging, left, inside, present, delta in itertools.product(range(4), range(5), range(2), range(2), range(2), range(2), (-3, 3)):
        records.append(record(3, (65535, 65535), authority=authority, kind=kind, dragging=dragging, left=left, inside=inside, position_present=present, delta=delta))
    generator = random.Random(0x74656c6172)
    now = 0
    for _ in range(random_cases):
        if generator.randrange(2):
            now = max(0, now + generator.randrange(-interval, interval * 2))
            records.append(record(1, (generator.randrange(3), generator.randrange(2)), now))
        else:
            records.append(record(2, precise=generator.randrange(2), cell_height=generator.choice((1, 2, 16)), delta=generator.randrange(-10000, 10001) / 100, phase=generator.randrange(5)))
    return records


def main():
    parser = argparse.ArgumentParser(description="Compare pointer decisions, click timing and scroll quantization with Zig")
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--random-cases", type=int, default=20000)
    arguments = parser.parse_args()
    if arguments.random_cases < 0:
        parser.error("--random-cases must be nonnegative")
    service = Path(__file__).resolve().parents[1]
    repository = service.parents[1]
    pointer_source = (repository / "src/client/input/copy_mode_pointer.zig").read_text()
    gui_source = (repository / "src/gui/GuiAdapter.zig").read_text()
    declarations = "\n".join(declaration(pointer_source, marker) for marker in ("pub const Authority =", "pub const Outcome =", "const CopyModePointerCommand ="))
    zig = zig_probe.replace("@pointer_declarations@", declarations).replace("@pointer_route@", declaration(pointer_source, "fn route("))
    zig = zig.replace("@scroll_route@", declaration(gui_source, "fn dispatchScroll("))
    records = corpus(arguments.random_cases)
    request = b"".join(request_format.pack(*entry) for entry in records)
    with tempfile.TemporaryDirectory(prefix="telar-pointer-") as directory:
        temporary = Path(directory)
        cpp_source, zig_source = temporary / "probe.cpp", temporary / "probe.zig"
        cpp_binary, zig_binary = temporary / "cpp_probe", temporary / "zig_probe"
        cpp_source.write_text(cpp_probe)
        zig_source.write_text(zig)
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", f"-I{service}", f"-I{repository / 'services/runtime-cpp'}", f"-I{repository / 'dlls/telar-client/include'}", str(cpp_source), "-o", str(cpp_binary)], check=True)
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "keyinput", "--dep", "cellgrid", "--dep", "scroll_event", "--dep", "input_limit", f"-Mroot={zig_source}", f"-Mkeyinput={repository / 'lib/keyinput/root.zig'}", f"-Mcellgrid={repository / 'lib/cellgrid/root.zig'}", f"-Mscroll_event={repository / 'lib/window/input/ScrollEvent.zig'}", f"-Minput_limit={repository / 'src/gui/InputLimit.zig'}", f"-femit-bin={zig_binary}"], check=True)
        reference = subprocess.run([str(zig_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
        candidate = subprocess.run([str(cpp_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
    if len(reference) != len(records) * result_format.size or len(candidate) != len(reference):
        raise SystemExit("Unexpected probe result length")
    for index, entry in enumerate(records):
        offset = index * result_format.size
        expected = reference[offset:offset + result_format.size]
        actual = candidate[offset:offset + result_format.size]
        if expected != actual:
            raise SystemExit(f"Record {index}, request {dict(zip(request_fields, entry))}: Zig {result_format.unpack(expected)}, C++ {result_format.unpack(actual)}")
    print(f"Matched {len(records)} pointer, click and scroll records byte-for-byte against the original Zig implementations")


if __name__ == "__main__":
    main()
