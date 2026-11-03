import argparse
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


cpp_probe = r"""
#include "history/plain_text.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <span>

int main() {
  constexpr std::size_t maximum_record_bytes = std::size_t{64} * 1024;
  constexpr auto header_bytes = telar::frame_prefix_size * 2;
  std::array<char, header_bytes> header{};
  std::array<char, maximum_record_bytes> input{};
  std::array<char, maximum_record_bytes> output{};
  while (std::cin.read(header.data(), static_cast<std::streamsize>(header.size()))) {
    auto fields = telar::byteView({header.data(), header.size()});
    const auto length = telar::u32::decode(fields);
    const auto capacity = telar::u32::decode(fields);
    if (length > input.size() || capacity > output.size()) {
      return 1;
    }

    if (!std::cin.read(input.data(), static_cast<std::streamsize>(length))) {
      return 1;
    }

    const auto bytes = telar::byteView({input.data(), length});
    const auto written = telar::gui::PlainText::strip(bytes, std::span{output}.first(capacity));
    std::array<telar::Byte, telar::frame_prefix_size> prefix{};
    std::span<telar::Byte> encoded{prefix};
    telar::u32::encode(static_cast<std::uint32_t>(written), encoded);
    const auto prefix_text = telar::textView(prefix);
    std::cout.write(prefix_text.data(), static_cast<std::streamsize>(prefix_text.size()));
    std::cout.write(output.data(), static_cast<std::streamsize>(written));
    if (!std::cout) {
      return 1;
    }
  }

  return std::cin.gcount() == 0 && std::cin.eof() ? 0 : 1;
}
"""


zig_probe = r"""
const original = @import("original");

extern "c" fn getchar() c_int;
extern "c" fn putchar(character: c_int) c_int;

const length_bytes = @sizeOf(u32);
const byte_bits = 8;
const byte_mask = 255;
const maximum_record_bytes = 64 * 1024;

fn readWord() !?u32 {
    const first = getchar();
    if (first < 0) {
        return null;
    }

    var word: u32 = @intCast(first);
    for (1..length_bytes) |index| {
        const byte = getchar();
        if (byte < 0) {
            return error.TruncatedHeader;
        }

        word |= @as(u32, @intCast(byte)) << @intCast(index * byte_bits);
    }

    return word;
}

fn writeWord(word: u32) !void {
    for (0..length_bytes) |index| {
        const byte = (word >> @intCast(index * byte_bits)) & byte_mask;
        if (putchar(@intCast(byte)) < 0) {
            return error.OutputFailed;
        }
    }
}

pub fn main() !void {
    var input: [maximum_record_bytes]u8 = @splat(0);
    var output: [maximum_record_bytes]u8 = @splat(0);
    while (try readWord()) |length| {
        const capacity = try readWord() orelse return error.TruncatedHeader;
        if (length > input.len or capacity > output.len) {
            return error.RecordTooLarge;
        }

        for (input[0..length]) |*byte| {
            const next = getchar();
            if (next < 0) {
                return error.TruncatedInput;
            }

            byte.* = @intCast(next);
        }

        const text = original.strip(input[0..length], output[0..capacity]);
        try writeWord(@intCast(text.len));
        for (text) |byte| {
            if (putchar(byte) < 0) {
                return error.OutputFailed;
            }
        }
    }
}
"""


def corpus(random_cases):
    prefixes = (b"", b"\x1b", b"\x1b(", b"\x1b[", b"\x1b]", b"\x1b]\x1b")
    byte_values = range(256)
    records = []
    for prefix in prefixes:
        for first in byte_values:
            for second in byte_values:
                text = prefix + bytes((first, second))
                records.append((text, len(text)))

    random_seed = 0x74656C6172
    generator = random.Random(random_seed)
    maximum_random_bytes = 1024
    for _ in range(random_cases):
        text = generator.randbytes(generator.randrange(maximum_random_bytes + 1))
        capacity = generator.randrange(len(text) + 2)
        records.append((text, capacity))

    records.extend(((b"content", 0), ("café\t🌱\n".encode(), 3)))
    return records


def decode_records(data):
    result = []
    position = 0
    length_bytes = struct.calcsize("<I")
    while position < len(data):
        length = struct.unpack_from("<I", data, position)[0]
        position += length_bytes
        end = position + length
        if end > len(data):
            raise ValueError("Truncated probe result")

        result.append(data[position:end])
        position = end

    return result


def main():
    parser = argparse.ArgumentParser(description="Compare the C++ terminal-output scanner with the original Zig implementation")
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--random-cases", type=int, default=5000)
    arguments = parser.parse_args()
    if arguments.random_cases < 0:
        parser.error("--random-cases must be nonnegative")

    service = Path(__file__).resolve().parents[1]
    repository = service.parents[1]
    records = corpus(arguments.random_cases)
    request = b"".join(struct.pack("<II", len(text), capacity) + text for text, capacity in records)
    with tempfile.TemporaryDirectory(prefix="telar-plain-text-") as directory:
        temporary = Path(directory)
        cpp_source = temporary / "cpp_probe.cpp"
        zig_source = temporary / "zig_probe.zig"
        cpp_binary = temporary / "cpp_probe"
        zig_binary = temporary / "zig_probe"
        cpp_source.write_text(cpp_probe)
        zig_source.write_text(zig_probe)
        subprocess.run([
            arguments.compiler, "-std=c++23", "-O2",
            f"-I{service}", f"-I{repository / 'dlls/telar-client/include'}", f"-I{repository / 'dlls/telar-base/include'}", f"-I{repository / 'dlls/telar-lua/include'}", f"-I{repository / 'dlls/telar-platform/include'}", f"-I{repository / 'dlls/telar-plugins/include'}", f"-I{repository / 'dlls/telar-config/include'}",
            str(cpp_source), "-o", str(cpp_binary),
        ], check=True)
        subprocess.run([
            arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "original",
            f"-Mroot={zig_source}", f"-Moriginal={repository / 'src/core/plain_text.zig'}",
            f"-femit-bin={zig_binary}",
        ], check=True)
        expected = subprocess.run([str(zig_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout
        actual = subprocess.run([str(cpp_binary)], input=request, stdout=subprocess.PIPE, check=True).stdout

    expected_records = decode_records(expected)
    actual_records = decode_records(actual)
    if len(expected_records) != len(records) or len(actual_records) != len(records):
        raise SystemExit("A probe returned an unexpected number of records")

    for index, (reference, candidate) in enumerate(zip(expected_records, actual_records, strict=True)):
        if reference != candidate:
            text, capacity = records[index]
            raise SystemExit(f"Mismatch at record {index}, capacity {capacity}, input {text.hex()}: Zig {reference.hex()}, C++ {candidate.hex()}")

    print(f"Matched {len(records)} records byte-for-byte against src/core/plain_text.zig")


if __name__ == "__main__":
    main()
