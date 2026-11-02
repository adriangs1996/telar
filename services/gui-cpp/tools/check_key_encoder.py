import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<13I")
result_format = struct.Struct("<II64s")

cpp_probe = r"""
#include "input/key_encoder.hpp"
#include <array>
#include <cstdint>
#include <iostream>

using namespace telar::gui;

struct Request {
  std::uint32_t code, scalar, modifiers, phase, flags, cursor, modify;
  std::uint32_t has_kitty, primary, has_shifted, shifted, has_base, base;
};

struct Result {
  std::uint32_t status = 0;
  std::uint32_t length = 0;
  std::array<char, 64> bytes{};
};

int main() {
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    TerminalKey key{
      .code = static_cast<KeyChord::Key>(request.code),
      .codepoint = request.scalar,
      .modifiers = request.modifiers,
      .phase = static_cast<KeyPhase>(request.phase),
    };
    if (request.has_kitty) {
      key.kitty = KittyCodepoints{.primary = request.primary};
      if (request.has_shifted) { key.kitty->shifted = request.shifted; }
      if (request.has_base) { key.kitty->base = request.base; }
    }
    telar::InputModes modes;
    modes.kitty_keyboard_flags = request.flags;
    modes.cursor_keys = request.cursor;
    modes.modify_other_keys_2 = request.modify;
    Result result;
    try {
      KeyEncoder encoder;
      const auto bytes = encoder.encode(key, modes);
      result.length = static_cast<std::uint32_t>(bytes.size());
      std::copy(bytes.begin(), bytes.end(), result.bytes.begin());
    } catch (const std::invalid_argument &) {
      result.status = 1;
    }
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
  }
}
"""

zig_probe = r"""
const std = @import("std");
const keyinput = @import("keyinput");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;

const Request = extern struct {
    code: u32, scalar: u32, modifiers: u32, phase: u32, flags: u32, cursor: u32, modify: u32,
    has_kitty: u32, primary: u32, has_shifted: u32, shifted: u32, has_base: u32, base: u32,
};

const Result = extern struct {
    status: u32 = 0,
    length: u32 = 0,
    bytes: [64]u8 = @splat(0),
};

fn makeKey(request: Request) !keyinput.Key {
    var bytes: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(@intCast(request.scalar), &bytes);
    const code: keyinput.Key.Code = switch (request.code) {
        0 => .{ .char = keyinput.Char.init(bytes[0..length]) },
        1 => .up, 2 => .down, 3 => .left, 4 => .right, 5 => .home, 6 => .end,
        7 => .delete, 8 => .page_up, 9 => .page_down, 10 => .enter, 11 => .escape,
        12 => .backspace, 13 => .tab, 14 => .back_tab,
        else => return error.InvalidCode,
    };
    return .{
        .code = code,
        .mods = .{
            .ctrl = request.modifiers & 1 != 0,
            .alt = request.modifiers & 2 != 0,
            .shift = request.modifiers & 4 != 0,
            .super = request.modifiers & 8 != 0,
        },
        .phase = @enumFromInt(request.phase + 1),
        .kitty = if (request.has_kitty != 0) .{
            .primary = request.primary,
            .shifted = if (request.has_shifted != 0) request.shifted else null,
            .base = if (request.has_base != 0) request.base else null,
        } else null,
    };
}

pub fn main() !void {
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
        var buffer: [keyinput.max_key_bytes]u8 = undefined;
        const key = try makeKey(request);
        const modes: keyinput.InputModes = .{
            .kitty_keyboard_flags = @intCast(request.flags),
            .cursor_keys = request.cursor != 0,
            .modify_other_keys_2 = request.modify != 0,
        };
        if (keyinput.encodeKey(&buffer, key, modes)) |encoded| {
            result.length = @intCast(encoded.len);
            @memcpy(result.bytes[0..encoded.len], encoded);
        } else |_| {
            result.status = 1;
        }
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


def record(code=0, scalar=97, modifiers=0, phase=0, flags=0, cursor=False, modify=False, kitty=None):
    primary, shifted, base = kitty if kitty is not None else (0, None, None)
    return (code, scalar, modifiers, phase, flags, int(cursor), int(modify), int(kitty is not None), primary, int(shifted is not None), shifted or 0, int(base is not None), base or 0)


def corpus(random_cases):
    scalars = tuple(dict.fromkeys((0, 9, 13, 27, 31, 32, 64, 97, 65, 90, 122, 127, 128, 159, 160, 255, 256, 2047, 2048, 55295, 57344, 63743, 65535, 65536, 127793, 1114111, *map(ord, "2345678[\\]^~_/?"))))
    records = []
    keys = [(0, scalar) for scalar in scalars] + [(code, 97) for code in range(1, 15)]
    for (code, scalar), modifiers, phase, flags, cursor, modify in itertools.product(keys, range(16), range(3), range(32), (False, True), (False, True)):
        records.append(record(code, scalar, modifiers, phase, flags, cursor, modify))
    metadata = ((97, None, None), (97, 65, None), (97, None, 113), (97, 0, 0), (57344, 65, 113), (63743, 1114111, 0xffffffff), (0xffffffff, 0xffffffff, 0xffffffff), (0, 55296, 0))
    for code, modifiers, phase, flags, kitty in itertools.product((0, 10, 11, 12, 13, 14, 1), range(16), range(3), range(32), metadata):
        records.append(record(code, modifiers=modifiers, phase=phase, flags=flags, kitty=kitty))
    generator = random.Random(0x74656c6172)
    for _ in range(random_cases):
        scalar = generator.randrange(1114112)
        if 55296 <= scalar <= 57343:
            scalar = 127793
        kitty = generator.choice(metadata) if generator.randrange(2) else None
        records.append(record(generator.randrange(15), scalar, generator.randrange(16), generator.randrange(3), generator.randrange(32), generator.randrange(2), generator.randrange(2), kitty))
    return records


def main():
    parser = argparse.ArgumentParser(description="Compare semantic key bytes against lib/keyinput/encoding.zig")
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--random-cases", type=int, default=25000)
    arguments = parser.parse_args()
    if arguments.random_cases < 0:
        parser.error("--random-cases must be nonnegative")
    service = Path(__file__).resolve().parents[1]
    repository = service.parents[1]
    records = corpus(arguments.random_cases)
    request = b"".join(request_format.pack(*entry) for entry in records)
    with tempfile.TemporaryDirectory(prefix="telar-key-encoder-") as directory:
        temporary = Path(directory)
        cpp_source, zig_source = temporary / "probe.cpp", temporary / "probe.zig"
        cpp_binary, zig_binary = temporary / "cpp_probe", temporary / "zig_probe"
        cpp_source.write_text(cpp_probe)
        zig_source.write_text(zig_probe)
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", f"-I{service}", f"-I{repository / 'services/runtime-cpp'}", f"-I{repository / 'dlls/telar-client/include'}", str(cpp_source), "-o", str(cpp_binary)], check=True)
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "keyinput", f"-Mroot={zig_source}", f"-Mkeyinput={repository / 'lib/keyinput/root.zig'}", f"-femit-bin={zig_binary}"], check=True)
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
    print(f"Matched {len(records)} semantic key encodings byte-for-byte against lib/keyinput/encoding.zig")


if __name__ == "__main__":
    main()
