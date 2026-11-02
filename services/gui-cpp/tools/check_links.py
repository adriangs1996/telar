import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<3I")
result_format = struct.Struct("<10I")

cpp_probe = r"""
#include "links/uri_recognizer.hpp"
#include "links/markdown_links.hpp"
#include "links/path_recognizer.hpp"
#include <array>
#include <cstdint>
#include <iostream>

using namespace telar::gui;
struct Request { std::uint32_t operation, offset, length; };
struct Result {
  std::uint32_t scheme = 0, start = 0, end = 0, destination_start = 0, destination_end = 0;
  std::uint32_t path_start = 0, path_end = 0, line = 0, column = 0, valid = 0;
};

int main() {
  Request request{};
  std::array<char, 65536> buffer;
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    if (request.length > buffer.size() || !std::cin.read(buffer.data(), request.length)) { return 1; }
    const std::string_view text{buffer.data(), request.length};
    Result result;
    std::optional<LinkTextMatch> match;
    if (request.operation == 0) {
      if (const auto scheme = UriRecognizer::classify(text)) {
        result.scheme = static_cast<std::uint32_t>(*scheme) + 1;
        result.valid = 1;
      }
    } else if (request.operation == 1) { match = UriRecognizer::extract(text, request.offset); }
    else if (request.operation == 2) { match = MarkdownLinks::extract(text, request.offset); }
    else if (request.operation == 3) { match = PathRecognizer::extract(text, request.offset); }
    else if (request.operation == 4) {
      const auto location = PathRecognizer::locate(text);
      result.path_end = location.path.size(); result.line = location.line; result.column = location.column; result.valid = 1;
    } else if (request.operation == 5) {
      if (const auto location = PathRecognizer::fragment(text)) {
        result.line = location->line; result.column = location->column; result.valid = 1;
      }
    } else { return 1; }
    if (match) {
      result.scheme = static_cast<std::uint32_t>(match->scheme) + 1;
      result.start = match->extent.start; result.end = match->extent.end;
      result.destination_start = match->destination.start; result.destination_end = match->destination.end; result.valid = 1;
    }
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
  }
}
"""

zig_probe = r"""
const std = @import("std");
const urlscan = @import("urlscan");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct { operation: u32, offset: u32, length: u32 };
const Result = extern struct {
    scheme: u32 = 0, start: u32 = 0, end: u32 = 0, destination_start: u32 = 0, destination_end: u32 = 0,
    path_start: u32 = 0, path_end: u32 = 0, line: u32 = 0, column: u32 = 0, valid: u32 = 0,
};
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
    var buffer: [65536]u8 = undefined;
    var request: Request = undefined;
    while (readExact(std.mem.asBytes(&request))) {
        if (request.length > buffer.len or !readExact(buffer[0..request.length])) return error.InvalidRequest;
        const text = buffer[0..request.length];
        var result: Result = .{};
        switch (request.operation) {
            0 => if (urlscan.classify(text)) |scheme| {
                result.scheme = @intFromEnum(scheme) + 1;
                result.valid = 1;
            },
            1, 3 => {
                const found = if (request.operation == 1) urlscan.extractAt(text, request.offset) else urlscan.pathAt(text, request.offset);
                if (found) |match| {
                    result.scheme = @intFromEnum(match.scheme) + 1;
                    result.start = @intCast(match.start); result.end = @intCast(match.end);
                    result.destination_start = result.start; result.destination_end = result.end; result.valid = 1;
                }
            },
            2 => if (urlscan.markdownLinkAt(text, request.offset)) |match| {
                result.scheme = @intFromEnum(match.scheme) + 1;
                result.start = @intCast(match.start); result.end = @intCast(match.end);
                result.destination_start = @intCast(match.destination[0]); result.destination_end = @intCast(match.destination[1]); result.valid = 1;
            },
            4 => {
                const location = urlscan.locatePath(text);
                result.path_end = @intCast(location.path.len); result.line = location.line; result.column = location.column; result.valid = 1;
            },
            5 => if (urlscan.locateFragment("", text)) |location| {
                result.line = location.line; result.column = location.column; result.valid = 1;
            },
            else => return error.InvalidOperation,
        }
        try writeAll(std.mem.asBytes(&result));
    }
}
"""


def requests():
    examples = [
        b"", b"https://example.com", b"HTTP://user:password@localhost:65535/a(b)c?q=x#part",
        b"file:///tmp/a.zig#L12:3", b"mailto:a@example.com", b"ssh:root@example.com",
        b"see (https://example.com/a(b)).", b"prefixhttps://example.com", b"(https://x/y)]!",
        b"[read the docs](https://example.com/a(b))", b"[nested [label]](http://x)",
        b"[broken](https://x title)", b"[path](src/main.cpp:12)", b"https://x/`https://y/",
        b"src/main.cpp:12:3", b"a.cpp:0", b"./a", b"../a", b"~/file", b"/tmp/a", b"and/or",
        b"a.cpp:1234567890", b"src/a.cpp:3:0000000001", b"src/a.cpp:123456789:9:12",
        "└src/añadir.cpp:42…".encode(), "src/中文.cpp:2".encode(), b"a:src/main.cpp:2",
        b"-src/file.cpp:2", b"//tmp/file", b"@src/file.cpp", b"foo/bar.cpp.",
    ]
    schemes = [b"http", b"https", b"file", b"mailto", b"ftp", b"ssh", b"git", b"tel", b"magnet", b"ipfs", b"ipns", b"gemini", b"gopher", b"news", b"custom"]
    hosts = [b"", b"/", b"x", b"user@", b"u:p@x", b"u:@x", b"]x", b"[::1]", b"[x]suffix", b"[x", b"x:0", b"x:+10", b"x:-0", b"x:-1", b"x:1__2", b"x:_12", b"x:12_", b"x:65536", b"x:0012", b"x:", b"[::1]:12", b"[::1]:bad"]
    for scheme, host in itertools.product(schemes, hosts):
        examples.append(scheme + b"://" + host + b"/a?b#c")
        examples.append(scheme.upper() + b":" + host)
    for byte in range(256):
        value = bytes([byte])
        examples.extend([b"https://x/" + value + b"z", b"[a" + value + b"b](http://x)", b"src/a" + value + b".cpp:12", b"http://x:" + value + b"12"])
    for size in [0, 1, 511, 512, 513, 4095, 4096, 4097, 4612, 9256]:
        examples.extend([b"http://x/" + (b"x" * size), b"[" + (b"a" * size) + b"](http://x)", b"/" + (b"a" * size)])
    for text in examples:
        yield 0, 0, text
        offsets = range(len(text) + 1) if len(text) < 128 else sorted({0, 1, len(text) // 2, max(0, len(text) - 1), len(text)})
        for offset in offsets:
            for operation in [1, 2, 3]:
                yield operation, offset, text
        yield 4, 0, text
    for fragment in [b"", b"12", b"L12", b"l12c3", b"L12:3", b"L12-L20", b"0", b"L000", b"L12-what", b"L12Cx", b"L123456789", b"L1234567890", b"L12#x"]:
        yield 5, 0, fragment
    randomizer = random.Random(0x4C494E4B)
    alphabet = b"abcXYZ0123456789:/._-~+@%()[]{}!?;,'\"# <>`\t\r\n" + bytes(range(128, 256))
    for _ in range(20000):
        prefix = bytes(randomizer.choices(alphabet, k=randomizer.randrange(32)))
        text = prefix + randomizer.choice(examples[:30]) + bytes(randomizer.choices(alphabet, k=randomizer.randrange(32)))
        offset = randomizer.randrange(len(text) + 2)
        for operation in [0, 1, 2, 3, 4, 5]:
            yield operation, offset, text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    corpus = list(requests())
    data = b"".join(request_format.pack(operation, offset, len(text)) + text for operation, offset, text in corpus)
    with tempfile.TemporaryDirectory(prefix="telar-links-") as directory:
        temporary = Path(directory)
        cpp = temporary / "probe.cpp"
        zig = temporary / "probe.zig"
        cpp.write_text(cpp_probe)
        zig.write_text(zig_probe)
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", "-I", str(root / "services/gui-cpp"), "-I", str(root / "services/runtime-cpp"), "-I", str(root / "dlls/telar-client/include"), str(cpp), "-o", str(temporary / "cpp")], check=True)
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", "--dep", "urlscan", f"-Mroot={zig}", f"-Murlscan={root / 'lib/urlscan/root.zig'}", f"-femit-bin={temporary / 'zig'}"], check=True)
        actual = subprocess.run([str(temporary / "cpp")], input=data, stdout=subprocess.PIPE, check=True).stdout
        expected = subprocess.run([str(temporary / "zig")], input=data, stdout=subprocess.PIPE, check=True).stdout
    expected_length = len(corpus) * result_format.size
    if len(actual) != expected_length or len(expected) != expected_length:
        raise SystemExit(f"Invalid output lengths: C++ {len(actual)}, Zig {len(expected)}, expected {expected_length}")
    for index, request in enumerate(corpus):
        start = index * result_format.size
        if actual[start:start + result_format.size] != expected[start:start + result_format.size]:
            raise SystemExit(f"Mismatch at {index}: {request!r}\nC++ {result_format.unpack_from(actual, start)}\nZig {result_format.unpack_from(expected, start)}")
    print(f"Matched {len(corpus):,} link recognition records against original Zig functions")


if __name__ == "__main__":
    main()
