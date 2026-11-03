import argparse
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile

from check_presentation import source_function


cpp_probe = r'''
#include "presentation/application_mark.hpp"
#include "graphics/artwork_resize.hpp"
#include "telar_config/agents/builtin_manifests.hpp"
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <span>
#include <string>
#include <vector>

template <typename Value>
bool read(Value &value) {
  return bool(std::cin.read(reinterpret_cast<char *>(&value), sizeof(value)));
}

int main(int argc, char **argv) {
  if (argc != 2) return 1;
  std::ifstream atlas(argv[1], std::ios::binary);
  std::vector<std::uint8_t> pixels{std::istreambuf_iterator<char>{atlas}, {}};
  if (pixels.size() != 320 * 64 * 4) return 2;
  std::uint8_t kind = 0;
  while (read(kind)) {
    if (kind == 0) {
      std::uint32_t length = 0;
      if (!read(length) || length > 4096) return 3;
      std::string name(length, '\0');
      if (!std::cin.read(name.data(), length)) return 3;
      const auto mark = telar::gui::ApplicationMark::forApplication(name);
      const std::array<std::uint8_t, 4> fields{
        static_cast<std::uint8_t>(mark.provider), static_cast<std::uint8_t>(mark.followsTheme()),
        static_cast<std::uint8_t>(mark.glyph.size()),
        static_cast<std::uint8_t>(telar::runtime::builtin_manifests.fromExecutable(name))};
      std::cout.write(reinterpret_cast<const char *>(fields.data()), fields.size());
      std::cout.write(mark.glyph.data(), mark.glyph.size());
    } else if (kind == 1) {
      std::array<std::uint32_t, 5> request{};
      if (!read(request)) return 4;
      const auto [offset, stride, width, height, side] = request;
      if (offset >= pixels.size() || side > 128) return 4;
      const telar::gui::RgbaImageView source{std::as_bytes(std::span{pixels}).subspan(offset), stride, width, height};
      std::vector<std::uint8_t> output(side * side * 4);
      if (!telar::gui::ArtworkResize::square(source, output, side)) return 5;
      telar::gui::ArtworkResize::premultiply(output);
      std::cout.write(reinterpret_cast<const char *>(output.data()), output.size());
    } else return 6;
  }
}
'''

zig_probe = r'''
const std = @import("std");
const icons = @import("icons");
const core = @import("telar-core");
const resize = @import("resize");
const premultiply = @import("premultiply");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;

fn readUnsigned(comptime Value: type) !Value {
    var result: Value = 0;
    for (0..@sizeOf(Value)) |index| {
        const byte = getchar();
        if (byte < 0) return error.TruncatedInput;
        result |= @as(Value, @intCast(byte)) << @intCast(index * 8);
    }
    return result;
}

fn write(bytes: []const u8) !void {
    for (bytes) |byte| {
        if (putchar(byte) < 0) return error.OutputFailed;
    }
}

pub fn main() !void {
    const atlas = @embedFile("atlas.rgba");
    while (true) {
        const kind = getchar();
        if (kind < 0) return;
        switch (kind) {
            0 => {
                const length = try readUnsigned(u32);
                var bytes: [4096]u8 = undefined;
                if (length > bytes.len) return error.TooLarge;
                for (bytes[0..length]) |*byte| byte.* = try readUnsigned(u8);
                const name = bytes[0..length];
                const icon = icons.Icon.forApplication(name);
                const provider: core.AgentProvider = switch (icon) {
                    .provider_claude => .claude, .provider_codex => .codex,
                    .provider_pi => .pi, .provider_cursor => .cursor,
                    .provider_opencode => .opencode, else => .unknown,
                };
                const glyph = icon.nerdGlyph();
                try write(&.{@intFromEnum(provider), @intFromBool(icons.providerMarkFollowsTheme(provider)), @intCast(glyph.len), @intFromEnum(core.builtin_table.providerFromExecutable(name) orelse .unknown)});
                try write(glyph);
            },
            1 => {
                const offset = try readUnsigned(u32);
                const stride = try readUnsigned(u32);
                const width = try readUnsigned(u32);
                const height = try readUnsigned(u32);
                const side = try readUnsigned(u32);
                var storage: [128 * 128 * 4]u8 = undefined;
                const output = storage[0 .. side * side * 4];
                resize.square(.{.pixels = atlas[offset..], .stride = stride, .width = width, .height = height}, output, side);
                premultiply.inPlace(output);
                try write(output);
            },
            else => return error.UnknownRequest,
        }
    }
}
'''

core_template = r'''
const std = @import("std");
__PROVIDER__
__MATCHER__
const types = @This();
const agent_manifest = @This();
const ProcessNames = struct {
    names: []const []const u8,
    count: usize,
    pub fn get(self: ProcessNames, index: usize) []const u8 { return self.names[index]; }
};
const Manifest = struct {
    provider: AgentProvider,
    display: []const u8,
    process_names: ProcessNames,
    pub fn displayName(self: *const Manifest) []const u8 { return self.display; }
};
const manifests = [_]Manifest{__MANIFESTS__};
const AgentManifest = Manifest;
const Table = struct {
    items: []const Manifest = &manifests,
    count: usize = manifests.len,
    __TABLE_FUNCTIONS__
};
pub const builtin_table: Table = .{};
'''


def reference_core(root):
    schema = (root / "src/core/schema/types.zig").read_text()
    provider = re.search(r"pub const AgentProvider = enum\(u8\) \{.*?\n\};", schema, re.S).group()
    source = (root / "src/core/agent_manifest.zig").read_text()
    entries = []
    names = []
    for match in re.finditer(r'const (\w+) = table.add\("(\w+)"\)', source):
        variable, name = match.groups()
        display = re.search(rf'{variable}\.setDisplayName\("([^"]+)"\)', source).group(1)
        individual = re.findall(rf'{variable}\.process_names.append\("([^"]+)"\)', source)
        arrays = re.findall(rf'for \(\[_\]\[\]const u8\{{([^}}]+)\}}\) \|name\| {variable}\.process_names.append\(name\)', source)
        processes = individual + [process for array in arrays for process in re.findall(r'"([^"]+)"', array)]
        if not processes:
            raise RuntimeError(f"No original executable names extracted for {name}")
        entries.append(f'.{{.provider=.{name}, .display="{display}", .process_names=.{{.count={len(processes)}, .names=&.{{' + ",".join(json.dumps(process) for process in processes) + "}}}")
        names.extend([display, *processes])
    if len(entries) != 5:
        raise RuntimeError(f"Expected five built-in providers, found {len(entries)}")
    matcher = "\n".join(source_function(source, marker) for marker in ("pub fn equalExecutableName(", "fn endsWithAsciiInsensitive("))
    core = core_template.replace("__PROVIDER__", provider).replace("__MATCHER__", matcher).replace("__MANIFESTS__", ",\n".join(entries))
    table = (root / "src/core/Table.zig").read_text()
    table_functions = "\n".join(source_function(table, marker) for marker in ("pub fn slice(", "pub fn providerFromExecutable("))
    return core.replace("__TABLE_FUNCTIONS__", table_functions), names


def mark_records(names):
    seeds = ["", "shell", "sh", "bash", "cursor", "nvim", "vim", "vi", "git", "lazygit", "Claude code", "Claude Code.exe", "Cursor Agent.cmd", "中", "🧶", *names]
    for name, transform, suffix in itertools.product(seeds, (str, str.upper, str.lower, str.swapcase), ("", ".exe", ".EXE", ".cmd", ".BAT", ".js", ".JS", ".exe.js", "/", " ", "\0")):
        encoded = (transform(name) + suffix).encode()
        yield bytes([0]) + struct.pack("<I", len(encoded)) + encoded
    randomizer = random.Random(20261026)
    for _ in range(10_000):
        encoded = randomizer.randbytes(randomizer.randrange(65))
        yield bytes([0]) + struct.pack("<I", len(encoded)) + encoded


def raster_records():
    for slot, side in itertools.product(range(5), range(8, 97)):
        yield bytes([1]) + struct.pack("<5I", slot * 64 * 4, 320 * 4, 64, 64, side)
    randomizer = random.Random(61983)
    for _ in range(1000):
        width, height = randomizer.randint(1, 64), randomizer.randint(1, 64)
        x, y = randomizer.randint(0, 320 - width), randomizer.randint(0, 64 - height)
        side = randomizer.randint(1, 128)
        yield bytes([1]) + struct.pack("<5I", (y * 320 + x) * 4, 320 * 4, width, height, side)


def output_length(record, output, offset):
    return 4 + output[offset + 2] if record[0] == 0 else struct.unpack_from("<I", record, 17)[0] ** 2 * 4


def main():
    parser = argparse.ArgumentParser(description="Compare application marks and artwork pixels with the Zig GUI")
    parser.add_argument("--compiler", default="clang++")
    parser.add_argument("--sanitizers", action="store_true")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    core, names = reference_core(root)
    records = list(itertools.chain(mark_records(names), raster_records()))
    payload = b"".join(records)
    atlas = root / "src/assets/provider-symbols-320x64.rgba"
    with tempfile.TemporaryDirectory(prefix="telar-application-marks-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(zig_probe)
        (work / "core.zig").write_text(core)
        (work / "atlas.rgba").write_bytes(atlas.read_bytes())
        includes = ["-I" + str(root / "services" / name) for name in ("gui-cpp",)] + ["-I" + str(root / "dlls/telar-client/include"), "-I" + str(root / "dlls/telar-base/include"), "-I" + str(root / "dlls/telar-lua/include"), "-I" + str(root / "dlls/telar-platform/include"), "-I" + str(root / "dlls/telar-plugins/include"), "-I" + str(root / "dlls/telar-config/include")]
        sanitizers = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"] if options.sanitizers else []
        subprocess.run([options.compiler, "-std=c++23", "-O2", "-ffp-contract=off", *sanitizers, *includes, str(work / "probe.cpp"), "-o", str(work / "cpp")], check=True)
        subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "icons", "--dep", "telar-core", "--dep", "resize", "--dep", "premultiply", f"-Mroot={work / 'probe.zig'}", "--dep", "telar-core", f"-Micons={root / 'src/model/layout/icons.zig'}", f"-Mtelar-core={work / 'core.zig'}", f"-Mresize={root / 'lib/imaging/resize.zig'}", f"-Mpremultiply={root / 'lib/imaging/premultiply.zig'}", f"-femit-bin={work / 'zig'}"], check=True)
        expected = subprocess.run([str(work / "zig")], input=payload, capture_output=True, check=True).stdout
        actual = subprocess.run([str(work / "cpp"), str(atlas)], input=payload, capture_output=True, check=True).stdout
        actual_offset = expected_offset = 0
        for index, record in enumerate(records):
            expected_length = output_length(record, expected, expected_offset)
            actual_length = output_length(record, actual, actual_offset)
            reference = expected[expected_offset:expected_offset + expected_length]
            result = actual[actual_offset:actual_offset + actual_length]
            if reference != result:
                mismatch = next((byte for byte, (left, right) in enumerate(zip(reference, result)) if left != right), None)
                raise RuntimeError(f"Mismatch at record {index}, input={record!r}, first byte={mismatch}, expected={reference[mismatch:mismatch + 16] if mismatch is not None else reference!r}, actual={result[mismatch:mismatch + 16] if mismatch is not None else result!r}")
            expected_offset += expected_length
            actual_offset += actual_length
        if expected_offset != len(expected) or actual_offset != len(actual):
            raise RuntimeError("Unexpected trailing probe output")
    print(f"Matched {len(records):,} application-mark records byte-for-byte, including {len(list(raster_records())):,} premultiplied RGBA images ({hashlib.sha256(expected).hexdigest()})")


if __name__ == "__main__":
    main()
