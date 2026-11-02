import argparse
import os
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile


cpp_probe = r"""
#include "links/link_gesture.hpp"
#include <array>
#include <cstdint>
#include <iostream>
#include <limits>

using namespace telar::gui;

struct Request {
  std::uint32_t action, present, mask, salt;
  std::array<std::uint64_t, VERSION_COUNT> version;
};

LinkHit makeHit(const Request &request) {
  const auto field = [&](unsigned index, unsigned original) {
    return original + (((request.mask >> index) & 1) ? (request.salt % 97) + 1 : 0);
  };
  const auto text = (request.mask & (1u << 20)) ? "https://changed.test/ñ" : "https://original.test";
  const auto target = (request.mask & (1u << 21)) ? LinkTarget::fromPath(text) : LinkTarget::fromUri(text);
  return {
    .pane_id = field(0, 1), .generation = field(1, 2),
    .location = {.workspace = {.kind = (request.mask & 4) ? telar::WorkspaceLocation::Kind::worktree : telar::WorkspaceLocation::Kind::workspace, .id = field(3, 1)}, .tab_id = field(4, 1)},
    .content = {.x = float(field(5, 1)), .y = float(field(6, 2)), .width = float(field(7, 80)), .height = float(field(8, 24))},
    .scroll_offset = field(9, 10),
    .area = {.x = float(field(10, 1)), .y = float(field(11, 2)), .width = float(field(12, 20)), .height = float(field(13, 1))},
    .match = {.target = *target, .start = {.x = std::uint16_t(field(14, 1)), .y = field(15, 10)}, .end = {.x = std::uint16_t(field(16, 20)), .y = field(17, 10)}, .metadata_index = (request.mask & (1u << 18)) ? std::optional<std::uint16_t>{std::uint16_t(field(19, 0))} : std::nullopt},
  };
}

void writeHit(const LinkHit &hit) {
  const std::array<std::uint64_t, 20> fields{
    hit.pane_id, hit.generation, std::uint64_t(hit.location.workspace.kind), hit.location.workspace.id, hit.location.tab_id,
    std::uint64_t(hit.content.x), std::uint64_t(hit.content.y), std::uint64_t(hit.content.width), std::uint64_t(hit.content.height), hit.scroll_offset,
    std::uint64_t(hit.area.x), std::uint64_t(hit.area.y), std::uint64_t(hit.area.width), std::uint64_t(hit.area.height),
    hit.match.start.x, hit.match.start.y, hit.match.end.x, hit.match.end.y,
    hit.match.metadata_index ? *hit.match.metadata_index : std::numeric_limits<std::uint64_t>::max(), std::uint64_t(hit.match.target.scheme()),
  };
  const auto text = hit.match.target.text();
  const auto size = std::uint32_t(text.size());
  std::cout.write(reinterpret_cast<const char *>(fields.data()), sizeof(fields));
  std::cout.write(reinterpret_cast<const char *>(&size), sizeof(size));
  std::cout.write(text.data(), text.size());
}

int main() {
  Request request{};
  LinkGesture gesture;
  const auto original = makeHit({});
  while (std::cin.read(reinterpret_cast<char *>(&request), sizeof(request))) {
    const auto hit = makeHit(request);
    const auto current = request.present ? std::optional{hit} : std::nullopt;
    ViewVersion version;
    VERSION_ASSIGNMENTS
    std::optional<LinkHit> opened;
    switch (request.action) {
    case 0: if (current) { gesture.begin(*current, version); } else { gesture.cancel(); } break;
    case 1: gesture.validate(current, version); break;
    case 2: opened = gesture.finish(current, version); break;
    case 3: gesture.cancel(); break;
    default: return 1;
    }
    const std::array<std::uint32_t, 3> result{gesture.active(), hit == original, opened.has_value()};
    std::cout.write(reinterpret_cast<const char *>(result.data()), sizeof(result));
    if (opened) { writeHit(*opened); }
  }
}
"""


zig_probe = r"""
const std = @import("std");
const data = @import("model");
const Hit = @import("hit");
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
const Request = extern struct {
    action: u32, present: u32, mask: u32, salt: u32,
    version: [VERSION_COUNT]u64,
};

fn field(request: Request, index: u5, original: u16) u16 {
    return original + if (request.mask & (@as(u32, 1) << index) != 0) @as(u16, @intCast(request.salt % 97 + 1)) else 0;
}

fn makeHit(request: Request) !Hit {
    const text = if (request.mask & (1 << 20) != 0) "https://changed.test/ñ" else "https://original.test";
    const target = if (request.mask & (1 << 21) != 0) try data.LinkTarget.initPath(text) else try data.LinkTarget.init(text);
    return .{
        .pane_id = @enumFromInt(field(request, 0, 1)), .generation = field(request, 1, 2),
        .location = .{ .workspace = if (request.mask & 4 != 0) .{ .worktree = @enumFromInt(field(request, 3, 1)) } else .{ .workspace = @enumFromInt(field(request, 3, 1)) }, .tab_id = @enumFromInt(field(request, 4, 1)) },
        .content = .{ .x = field(request, 5, 1), .y = field(request, 6, 2), .w = field(request, 7, 80), .h = field(request, 8, 24) },
        .scroll_offset = field(request, 9, 10),
        .area = .{ .x = field(request, 10, 1), .y = field(request, 11, 2), .w = field(request, 12, 20), .h = field(request, 13, 1) },
        .match = .{ .target = target, .start = .{ .x = field(request, 14, 1), .y = field(request, 15, 10) }, .end = .{ .x = field(request, 16, 20), .y = field(request, 17, 10) }, .link_index = if (request.mask & (1 << 18) != 0) field(request, 19, 0) else null },
    };
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

fn writeHit(hit: Hit) !void {
    const fields: [20]u64 = .{
        @intFromEnum(hit.pane_id), hit.generation, @intFromEnum(hit.location.workspace), switch (hit.location.workspace) { inline else => |id| @intFromEnum(id) }, @intFromEnum(hit.location.tab_id),
        hit.content.x, hit.content.y, hit.content.w, hit.content.h, hit.scroll_offset,
        hit.area.x, hit.area.y, hit.area.w, hit.area.h,
        hit.match.start.x, hit.match.start.y, hit.match.end.x, hit.match.end.y,
        if (hit.match.link_index) |index| index else std.math.maxInt(u64), @intFromEnum(hit.match.target.scheme),
    };
    const length: u32 = hit.match.target.len;
    try writeAll(std.mem.asBytes(&fields));
    try writeAll(std.mem.asBytes(&length));
    try writeAll(hit.match.target.uri());
}

pub fn main() !void {
    var request: Request = undefined;
    var gesture: LinkGesture = .{};
    const original = try makeHit(.{ .action = 0, .present = 0, .mask = 0, .salt = 0, .version = @splat(0) });
    while (readExact(std.mem.asBytes(&request))) {
        const hit = try makeHit(request);
        const current: ?Hit = if (request.present != 0) hit else null;
        var version: data.Version = .{};
        inline for (std.meta.fields(data.Version), 0..) |descriptor, index| {
            @field(version, descriptor.name) = request.version[index];
        }
        var opened: ?Hit = null;
        switch (request.action) {
            0 => if (current) |present| { gesture.begin(present, version); } else { gesture.cancel(); },
            1 => gesture.validate(current, version),
            2 => { opened = gesture.finish(current, version); },
            3 => gesture.cancel(),
            else => return error.InvalidAction,
        }
        const result: [3]u32 = .{ @intFromBool(gesture.pressed != null), @intFromBool(hit.eql(&original)), @intFromBool(opened != null) };
        try writeAll(std.mem.asBytes(&result));
        if (opened) |value| try writeHit(value);
    }
}
"""


def corpus(version_count):
    zero = (0,) * version_count

    def request(action, present=1, mask=0, salt=0, version=zero):
        return (action, present, mask, salt, *version)

    for bit in range(22):
        for salt in (0, 1, 255, 65535):
            yield request(0)
            yield request(1, mask=1 << bit, salt=salt)
            yield request(2)
            yield request(0, mask=1 << bit, salt=salt)
            yield request(2, mask=1 << bit, salt=salt)
    for index in range(version_count):
        for value in (1, 2**32 - 1, 2**64 - 1):
            version = list(zero)
            version[index] = value
            yield request(0)
            yield request(1, version=version)
            yield request(2)
            yield request(0, version=version)
            yield request(2, version=version)
    randomizer = random.Random(0x4C494E4B)
    for _ in range(12000):
        mask = randomizer.getrandbits(22)
        salt = randomizer.getrandbits(32)
        version = [randomizer.choice((0, 1, 2**64 - 1)) for _ in zero]
        yield request(0, mask=mask, salt=salt, version=version)
        yield request(1, mask=mask, salt=salt, version=version)
        yield request(2, mask=mask, salt=salt, version=version)
        yield request(0, mask=mask, salt=salt, version=version)
        yield request(1, present=randomizer.randrange(2), mask=randomizer.getrandbits(22), salt=salt, version=version)
        yield request(2, mask=mask, salt=salt, version=version)
        yield request(0, mask=mask, salt=salt, version=version)
        yield request(randomizer.choice((1, 3)), present=0)
        yield request(2, mask=mask, salt=salt, version=version)


def result_records(output, count):
    position = 0
    for _ in range(count):
        header = struct.unpack_from("<3I", output, position)
        end = position + struct.calcsize("<3I")
        if header[2]:
            length = struct.unpack_from("<I", output, end + struct.calcsize("<20Q"))[0]
            end += struct.calcsize("<20QI") + length
        yield output[position:end]
        position = end
    if position != len(output):
        raise SystemExit("Unexpected trailing probe output")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    version_fields = re.findall(r"^(\w+): u64", (root / "src/model/state/Version.zig").read_text(), re.MULTILINE)
    records = list(corpus(len(version_fields)))
    request_format = struct.Struct(f"<4I{len(version_fields)}Q")
    data = b"".join(request_format.pack(*record) for record in records)
    source = (root / "src/gui/WindowModel.zig").read_text()
    start = source.index("const LinkGesture = struct {")
    gesture = source[start:source.index("\n};", start) + len("\n};")]
    view_fields = ("workspace", "active_tab", "tabs", "panes", "host", "configuration", "viewport")
    assignments = "\n".join(f"version.{name} = request.version[{version_fields.index(name)}];" for name in view_fields)
    with tempfile.TemporaryDirectory(prefix="telar-link-gestures-") as directory:
        temporary = Path(directory)
        cpp = temporary / "probe.cpp"
        zig = temporary / "probe.zig"
        cpp.write_text(cpp_probe.replace("VERSION_COUNT", str(len(version_fields))).replace("VERSION_ASSIGNMENTS", assignments))
        zig.write_text(zig_probe.replace("VERSION_COUNT", str(len(version_fields))) + gesture)
        includes = [root / "services/gui-cpp", root / "services/runtime-cpp", root / "dlls/telar-client/include"]
        subprocess.run([arguments.compiler, "-std=c++23", "-O2", *[flag for directory in includes for flag in ("-I", str(directory))], str(cpp), "-o", str(temporary / "cpp")], check=True)
        modules = ["--dep", "model", "--dep", "hit", f"-Mroot={zig}"]
        modules += ["--dep", "telar-core", "--dep", "cellgrid", "--dep", "keyinput", "--dep", "urlscan", f"-Mmodel={root / 'src/model/model.zig'}"]
        modules += ["--dep", "model", "--dep", "telar-core", "--dep", "cellgrid", f"-Mhit={root / 'src/gui/input/LinkHit.zig'}"]
        modules += ["--dep", "cellgrid", "--dep", "keyinput", f"-Mtelar-core={root / 'src/core/core.zig'}"]
        modules += [f"-Mkeyinput={root / 'lib/keyinput/root.zig'}", f"-Mcellgrid={root / 'lib/cellgrid/root.zig'}", f"-Murlscan={root / 'lib/urlscan/root.zig'}"]
        subprocess.run([arguments.zig, "build-exe", "-O", "ReleaseSafe", "-lc", *modules, f"-femit-bin={temporary / 'zig'}"], check=True)
        actual = subprocess.run([str(temporary / "cpp")], input=data, stdout=subprocess.PIPE, check=True).stdout
        expected = subprocess.run([str(temporary / "zig")], input=data, stdout=subprocess.PIPE, check=True).stdout
    for index, (cpp_result, zig_result) in enumerate(zip(result_records(actual, len(records)), result_records(expected, len(records)), strict=True)):
        if cpp_result != zig_result:
            raise SystemExit(f"Mismatch at {index}: request {records[index]!r}\nC++ {cpp_result.hex()}\nZig {zig_result.hex()}")
    print(f"Matched {len(records):,} gesture transitions byte-for-byte against original WindowModel.LinkGesture and LinkHit.eql")


if __name__ == "__main__":
    main()
