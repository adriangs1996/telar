import argparse
import itertools
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile


request_format = struct.Struct("<7I")
result_format = struct.Struct("<4I")
length_format = struct.Struct("<I")

cpp_probe = r"""
#include "links/editor_launch.hpp"
#include "links/file_path.hpp"
#include "links/link_target.hpp"
#include "links/path_expansion.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

using namespace telar::gui;
struct Request { std::uint32_t mode, flags, line, column, first_size, second_size, third_size; };
struct Result { std::uint32_t error_size = 0, count = 0, line = 0, column = 0; };
struct Environment {
  std::optional<std::string_view> home;
  std::optional<std::string_view> operator()(std::string_view name) const {
    if (name == "HOME") { return home; }
    if (name == "PROJECT") { return "telar"; }
    if (name == "EMPTY") { return ""; }
    if (name == "ABS") { return "/absolute"; }
    return {};
  }
};
std::string readText(std::uint32_t size) {
  if (size > 8192) { throw std::runtime_error{"Invalid probe input"}; }
  std::string text(size, '\0');
  if (!std::cin.read(text.data(), size)) { throw std::runtime_error{"Incomplete probe input"}; }
  return text;
}
int main() {
  Request request{};
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    const auto first = readText(request.first_size);
    const auto second = readText(request.second_size);
    const auto third = readText(request.third_size);
    std::vector<std::string> fields;
    std::string failure;
    Result result;
    try {
      switch (request.mode) {
      case 0: {
        const auto target = request.flags ? LinkTarget::fromPath(first) : LinkTarget::fromUri(first);
        if (!target) { throw std::invalid_argument{"InvalidLink"}; }
        const auto path = FilePath::parse(*target);
        fields.emplace_back(path.text());
        result.line = path.line(); result.column = path.column();
        break;
      }
      case 1: {
        EditorLaunch launch;
        for (const auto argument : launch.arguments(first, second, request.line, request.column)) {
          fields.emplace_back(argument);
        }
        break;
      }
      case 2: {
        const Environment environment{request.flags ? std::optional{std::string_view{third}} : std::nullopt};
        fields.emplace_back(PathExpansion::expand({.text = first, .base = second}, environment).view());
        break;
      }
      default: return 1;
      }
    } catch (const std::exception &error) {
      failure = error.what();
    }
    result.error_size = failure.size(); result.count = fields.size();
    std::cout.write(reinterpret_cast<const char *>(&result), sizeof(result));
    std::cout.write(failure.data(), failure.size());
    for (const auto &field : fields) {
      const auto length = static_cast<std::uint32_t>(field.size());
      std::cout.write(reinterpret_cast<const char *>(&length), sizeof(length));
      std::cout.write(field.data(), field.size());
    }
  }
}
"""

zig_probe = r"""
const std = @import("std");
const data = @import("model");
const editorremote = @import("editorremote");
const path_expansion = @import("path_expansion");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct { mode: u32, flags: u32, line: u32, column: u32, first_size: u32, second_size: u32, third_size: u32 };
const Result = extern struct { error_size: u32 = 0, count: u32 = 0, line: u32 = 0, column: u32 = 0 };
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
fn writeFields(fields: []const []const u8, line: u32, column: u32) !void {
    const result: Result = .{ .count = @intCast(fields.len), .line = line, .column = column };
    try writeAll(std.mem.asBytes(&result));
    for (fields) |field| {
        const length: u32 = @intCast(field.len);
        try writeAll(std.mem.asBytes(&length));
        try writeAll(field);
    }
}
fn process(request: Request, first: []const u8, second: []const u8, third: []const u8) !void {
    switch (request.mode) {
        0 => {
            const target = if (request.flags != 0) try data.LinkTarget.initPath(first) else try data.LinkTarget.init(first);
            const path = try data.FilePath.init(&target);
            try writeFields(&.{path.slice()}, path.line, path.column);
        },
        1 => {
            var launch: editorremote.Launch = .{};
            try writeFields(try launch.argv(first, second, request.line, request.column), 0, 0);
        },
        2 => {
            var home_storage: [8192]u8 = undefined;
            const home = try std.fmt.bufPrintZ(&home_storage, "HOME={s}", .{third});
            const entries = [_:null]?[*:0]const u8{home.ptr, "PROJECT=telar", "EMPTY=", "ABS=/absolute"};
            const environment: std.process.Environ = .{ .block = .{ .slice = if (request.flags != 0) &entries else entries[1..] } };
            var buffer: [path_expansion.max_path_bytes]u8 = undefined;
            const path = try path_expansion.expand(.{ .text = first, .base = second, .environ = environment }, &buffer);
            try writeFields(&.{path}, 0, 0);
        },
        else => return error.InvalidMode,
    }
}
pub fn main() !void {
    var request: Request = undefined;
    while (readExact(std.mem.asBytes(&request))) {
        var first: [8192]u8 = undefined;
        var second: [8192]u8 = undefined;
        var third: [8192]u8 = undefined;
        if (!readExact(first[0..request.first_size]) or !readExact(second[0..request.second_size]) or !readExact(third[0..request.third_size])) return error.IncompleteInput;
        process(request, first[0..request.first_size], second[0..request.second_size], third[0..request.third_size]) catch |err| {
            const name = @errorName(err);
            const result: Result = .{ .error_size = @intCast(name.len) };
            try writeAll(std.mem.asBytes(&result));
            try writeAll(name);
        };
    }
}
"""


def corpus():
    examples = [b"file:/tmp/a", b"file:///tmp/a%20b#L12C3-L20", b"file://LOCAL%68ost/a", b"file:/a?x", b"file://u:p@localhost/a", b"file:/a#0C3", b"https://x", b"file:/a%00", b"file:/a%ff"]
    for example in examples:
        yield 0, 0, 0, 0, example, b"", b""
        for index in range(len(example)):
            for byte in range(256):
                yield 0, 0, 0, 0, example[:index] + bytes([byte]) + example[index + 1:], b"", b""
    for byte in range(256):
        yield 0, 0, 0, 0, f"file:/tmp/a%{byte:02X}".encode(), b"", b""
    for host in [b"", b"localhost", b"LOCALHOST", b"%6cocalhost", b"remote", b"%", b"a" * 256, b"%61" * 256, b"a" * 255 + b"%"]:
        for fragment in [b"", b"#L12", b"#12:3", b"#0C3", b"#L1-L2", b"#L1234567890", b"#L1C", b"#", b"#other"]:
            yield 0, 0, 0, 0, b"file://" + host + b"/a" + fragment, b"", b""
    for path in [b"a.cpp:12:3", b"../src/a.cpp:0:3", b"-a.cpp", b":12", b"a:", b"/", b"\xff", b"a\x00", b"a" * 4096, b"a" * 4097]:
        yield 0, 1, 0, 0, path, b"", b""
    editors = [b"nvim", b"vim", b"vi", b"vim.nox", b"Vim", b"emacs", b"Emacs", b"emacsclient", b"emacs-30", b"kak", b"micro", b"nano", b"hx", b"helix", b"code", b"code-insiders", b"codium", b"cursor", b"unknown", b"nvim ", b""]
    paths = [b"/tmp/a $(id); 'quoted'.cpp", "/tmp/中.cpp".encode(), b"/" + b"a" * 4095]
    for editor, path, line, column in itertools.product(editors, paths, [0, 1, 12, 2**32 - 1], [0, 3, 2**32 - 1]):
        for prefix in [b"", b"/usr/local/bin/"]:
            yield 1, 0, line, column, prefix + editor, path, b""
    for editor in editors:
        for suffix in [b"/", b"//", b"///"]:
            yield 1, 0, 12, 3, b"/usr/bin/" + editor + suffix, b"/tmp/a", b""
    inputs = [b"", b" ", b"/", b"./a/../b//", b"../../../../x", b"~/x", b"~", b"~other/x", b"$PROJECT/../$PROJECT", b"${PROJECT}", b"${PROJECT", b"${}", b"$?", b"$", b"$EMPTY", b"$MISSING", b"$ABS/x", b"a\x00b", b"/a\x00b", b"a" * 4096]
    for text, base, home in itertools.product(inputs, [b"", b"relative", b"/work/project", b"/"], [None, b"", b"/home/reader", b"relative"]):
        yield 2, int(home is not None), 0, 0, text, base, home or b""
    randomizer = random.Random(0x46494C45)
    segments = [b"a", b"..", b".", b"", b"$PROJECT", b"${EMPTY}", b"${ABS}", b"$?", b"${MISSING}", b"$HOME"]
    for _ in range(12000):
        text = b"/".join(randomizer.choices(segments, k=randomizer.randrange(1, 12)))
        yield 2, 1, 0, 0, text, randomizer.choice([b"/work", b"/", b""]), b"/home/reader"


def records(output):
    offset = 0
    while offset < len(output):
        start = offset
        failure_size, count, _, _ = result_format.unpack_from(output, offset)
        offset += result_format.size + failure_size
        for _ in range(count):
            length, = length_format.unpack_from(output, offset)
            offset += length_format.size + length
        yield output[start:offset]
    if offset != len(output):
        raise SystemExit("Invalid probe output length")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    requests = list(corpus())
    data = b"".join(request_format.pack(*request[:4], *(len(text) for text in request[4:])) + b"".join(request[4:]) for request in requests)
    with tempfile.TemporaryDirectory(prefix="telar-file-links-") as directory:
        temporary = Path(directory)
        cpp = temporary / "probe.cpp"
        zig = temporary / "probe.zig"
        cpp.write_text(cpp_probe)
        zig.write_text(zig_probe)
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", "-I", str(root / "services/gui-cpp"), "-I", str(root / "services/runtime-cpp"), "-I", str(root / "services/desktop-mode"), str(cpp), "-o", str(temporary / "cpp")], check=True)
        modules = ["--dep", "model", "--dep", "editorremote", "--dep", "path_expansion", f"-Mroot={zig}"]
        modules += ["--dep", "telar-core", "--dep", "cellgrid", "--dep", "keyinput", "--dep", "urlscan", f"-Mmodel={root / 'src/model/model.zig'}"]
        modules += ["--dep", "cellgrid", "--dep", "keyinput", f"-Mtelar-core={root / 'src/core/core.zig'}"]
        modules += ["--dep", "model", f"-Mpath_expansion={root / 'src/client/completion/path_expansion.zig'}"]
        modules += [f"-Meditorremote={root / 'lib/editorremote/root.zig'}", f"-Mkeyinput={root / 'lib/keyinput/root.zig'}", f"-Mcellgrid={root / 'lib/cellgrid/root.zig'}", f"-Murlscan={root / 'lib/urlscan/root.zig'}"]
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseFast", "-lc", *modules, f"-femit-bin={temporary / 'zig'}"], check=True)
        actual = list(records(subprocess.run([str(temporary / "cpp")], input=data, stdout=subprocess.PIPE, check=True).stdout))
        expected = list(records(subprocess.run([str(temporary / "zig")], input=data, stdout=subprocess.PIPE, check=True).stdout))
    if len(actual) != len(requests) or len(expected) != len(requests):
        raise SystemExit("Unexpected probe result count")
    for index, (received, reference) in enumerate(zip(actual, expected)):
        if received != reference:
            raise SystemExit(f"Mismatch at {index}: {requests[index]!r}\nC++ {received!r}\nZig {reference!r}")
    print(f"Matched {len(requests):,} file-link, editor-argument and path-expansion records byte-for-byte against original Zig functions")


if __name__ == "__main__":
    main()
