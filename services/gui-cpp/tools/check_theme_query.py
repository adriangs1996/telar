import argparse
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile


cpp_probe = r"""
#include "config/theme_query.hpp"
#include "config/themes.hpp"
#include "core/theme_values.hpp"
#include "tests/json_fixture.hpp"
#include "text/json.hpp"
#include <array>
#include <bit>
#include <charconv>
#include <cstdint>
#include <iostream>
#include <string>
using namespace telar::gui;
using telar::gui::test::requiredJsonField;
using telar::runtime::JsonValue;

std::uint64_t number(const JsonValue &value, std::string_view name) {
  const auto text = requiredJsonField(value, name).encoded();
  std::uint64_t result = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{}) {
    throw std::runtime_error{"Invalid oracle input"};
  }
  return result;
}

ThemeValues preset(std::uint64_t index) {
  return theme_presets.at(index).values;
}

ThemeRgb rgb(std::uint64_t encoded) {
  return {static_cast<telar::Byte>(encoded >> 16), static_cast<telar::Byte>(encoded >> 8), static_cast<telar::Byte>(encoded)};
}

telar::CellColor color(const JsonValue &operation) {
  const auto kind = number(operation, "color_kind");
  const auto bytes = rgb(number(operation, "rgb"));
  return {.kind = static_cast<telar::CellColor::Kind>(kind), .channels = kind == 0 ? ThemeRgb{} : kind == 1 ? ThemeRgb{bytes[2], 0, 0}
                                                                                                            : bytes};
}

void mutate(ThemeSelection &selection, const JsonValue &operation) {
  auto *theme = &selection.base;
  const auto target = number(operation, "target");
  if (target == 1) {
    theme = &selection.light.value();
  } else if (target == 2) {
    theme = &selection.dark.value();
  }
  const auto index = number(operation, "index");
  const auto value = rgb(number(operation, "rgb"));
  const auto clear = requiredJsonField(operation, "clear").boolean();
  switch (number(operation, "kind")) {
  case 0:
    theme->palette.at(index) = color(operation);
    break;
  case 1:
    theme->terminal.foreground = value;
    break;
  case 2:
    theme->terminal.background = value;
    break;
  case 3:
    theme->terminal.cursor_color = clear ? std::nullopt : std::optional{value};
    break;
  case 4:
    theme->terminal.cursor_text_color = clear ? std::nullopt : std::optional{value};
    break;
  case 5:
    theme->terminal.palette.at(index) = value;
    break;
  case 6:
    theme->syntax_styles.at(index) = clear ? std::nullopt : std::optional{SyntaxStyleValues{.color = color(operation), .italic = requiredJsonField(operation, "italic").boolean(), .bold = requiredJsonField(operation, "bold").boolean()}};
    break;
  }
}

void emit(const ThemeSelection &selection, std::span<char> output) {
  try {
    std::cout << ThemeQuery::write(selection, output) << '\n';
  } catch (const std::length_error &error) {
    if (std::string_view{error.what()} != "WriteFailed") {
      throw;
    }
    std::cout << "\"WriteFailed\"\n";
  }
}

void utf8() {
  std::uint64_t count = 0, total = 0;
  for (std::uint32_t encoded = 0; encoded <= 0xffffff; ++encoded) {
    const auto bytes = std::bit_cast<std::array<char, 3>>(rgb(encoded));
    if (telar::inspectUtf8({bytes.data(), bytes.size()}) == telar::Utf8Validation::valid) {
      ++count;
      total += encoded;
    }
  }
  std::cout << count << ' ' << total << '\n';
}

void run(const JsonValue &request) {
  if (requiredJsonField(request, "utf8").boolean()) {
    utf8();
    return;
  }
  ThemeSelection selection{.base = preset(number(request, "base"))};
  const auto light = number(request, "light"), dark = number(request, "dark"), lock = number(request, "lock");
  if (light < theme_presets.size()) {
    selection.light = preset(light);
  }
  if (dark < theme_presets.size()) {
    selection.dark = preset(dark);
  }
  std::optional<ThemeValues> locked;
  if (lock < theme_presets.size()) {
    locked = preset(lock);
  }
  requiredJsonField(request, "operations").eachElement([&](const JsonValue &operation) {
    mutate(selection, operation);
  });
  std::array<char, 65536> output{};
  emit(selection, std::span{output}.first(number(request, "capacity")));
  auto selected = selection.resolve(static_cast<Appearance>(number(request, "appearance")), locked);
  emit(ThemeSelection{.base = selected}, output);
  for (std::size_t index = 0; index < selected.syntax_styles.size(); ++index) {
    selected.syntax_styles[index] = selected.syntaxStyle(static_cast<SyntaxRole>(index));
  }
  emit(ThemeSelection{.base = selected}, output);
}

int main() {
  for (std::string line; std::getline(std::cin, line);) {
    run(JsonValue::parse(line));
  }
}
"""

zig_probe = r"""const std = @import("std");
const support = @import("theme_support");
const Color = @import("color").Color;
const data = struct {
    const HostAppearance = @import("appearance").HostAppearance;
};
const Snapshot = struct { theme: support.Theme, theme_light: ?support.Theme = null, theme_dark: ?support.Theme = null };
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn number(value: std.json.Value, name: []const u8) !u64 {
    return std.fmt.parseInt(u64, value.object.get(name).?.number_string, 10);
}
fn preset(index: u64) support.Theme {
    return support.builtin(@enumFromInt(index));
}
fn rgb(encoded: u64) [3]u8 {
    return .{ @truncate(encoded >> 16), @truncate(encoded >> 8), @truncate(encoded) };
}
fn color(operation: std.json.Value) !Color {
    const kind = try number(operation, "color_kind");
    const bytes = rgb(try number(operation, "rgb"));
    return switch (kind) {
        0 => .default,
        1 => .indexed(bytes[2]),
        else => .rgb(bytes),
    };
}
fn mutate(snapshot: *Snapshot, operation: std.json.Value) !void {
    const target = try number(operation, "target");
    const theme = if (target == 1) &snapshot.theme_light.? else if (target == 2) &snapshot.theme_dark.? else &snapshot.theme;
    const index = try number(operation, "index");
    const value = rgb(try number(operation, "rgb"));
    const clear = operation.object.get("clear").?.bool;
    switch (try number(operation, "kind")) {
        0 => inline for (std.meta.fields(@TypeOf(theme.palette)), 0..) |field, position| {
            if (position == index) {
                @field(theme.palette, field.name) = try color(operation);
            }
        },
        1 => theme.terminal.foreground = value,
        2 => theme.terminal.background = value,
        3 => theme.terminal.cursor_color = if (clear) null else value,
        4 => theme.terminal.cursor_text_color = if (clear) null else value,
        5 => theme.terminal.palette[index] = value,
        6 => theme.syntax_styles.set(@enumFromInt(index), if (clear) null else .{ .color = try color(operation), .italic = operation.object.get("italic").?.bool, .bold = operation.object.get("bold").?.bool }),
        else => unreachable,
    }
}
fn original(snapshot: *const Snapshot, writer: *std.Io.Writer) !void {
    __QUERY__;
}
fn resolve(self: *const Snapshot, appearance: data.HostAppearance, locked: ?support.Theme) support.Theme {
    __RESOLVE__
}
fn emit(snapshot: *const Snapshot, capacity: usize) !void {
    var output: [65536]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output[0..capacity]);
    if (original(snapshot, &writer)) |_| {
        for (writer.buffered()) |byte| {
            _ = putchar(byte);
        }
    } else |err| {
        if (err != error.WriteFailed) {
            return err;
        }
        for ("\"WriteFailed\"") |byte| {
            _ = putchar(byte);
        }
    }
    _ = putchar('\n');
}
fn utf8() void {
    var count: u64 = 0;
    var total: u64 = 0;
    var encoded: u32 = 0;
    while (encoded <= 0xffffff) : (encoded += 1) {
        const bytes = rgb(encoded);
        if (std.unicode.utf8ValidateSlice(&bytes)) {
            count += 1;
            total += encoded;
        }
    }
    var output: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&output, "{d} {d}\n", .{ count, total }) catch unreachable;
    for (text) |byte| {
        _ = putchar(byte);
    }
}
fn run(source: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, source, .{ .parse_numbers = false });
    defer parsed.deinit();
    const request = parsed.value;
    if (request.object.get("utf8").?.bool) {
        utf8();
        return;
    }
    var snapshot: Snapshot = .{ .theme = preset(try number(request, "base")) };
    const light = try number(request, "light");
    const dark = try number(request, "dark");
    const lock = try number(request, "lock");
    if (light < 9) {
        snapshot.theme_light = preset(light);
    }
    if (dark < 9) {
        snapshot.theme_dark = preset(dark);
    }
    const locked = if (lock < 9) preset(lock) else null;
    for (request.object.get("operations").?.array.items) |operation| {
        try mutate(&snapshot, operation);
    }
    try emit(&snapshot, @intCast(try number(request, "capacity")));
    var selected: Snapshot = .{ .theme = resolve(&snapshot, @enumFromInt(try number(request, "appearance")), locked) };
    try emit(&selected, 65536);
    inline for (0..15) |index| {
        selected.theme.syntax_styles.set(@enumFromInt(index), selected.theme.syntaxStyle(@enumFromInt(index)));
    }
    try emit(&selected, 65536);
}
pub fn main() !void {
    var source: [65536]u8 = undefined;
    var length: usize = 0;
    while (true) {
        const byte = getchar();
        if (byte < 0) {
            break;
        }
        if (byte == '\n') {
            try run(source[0..length]);
            length = 0;
        } else {
            source[length] = @intCast(byte);
            length += 1;
        }
    }
}
"""


def records():
    generator = random.Random(0x5448454D45)
    default = dict(
        utf8=False,
        base=0,
        light=9,
        dark=9,
        lock=9,
        appearance=0,
        capacity=4096,
        operations=[],
    )
    for base in range(9):
        for appearance in range(3):
            for lock in (base, 9):
                yield {**default, "base": base, "appearance": appearance, "lock": lock}
    for index in range(2048):
        value = {
            **default,
            "base": index % 9,
            "light": generator.randrange(10),
            "dark": generator.randrange(10),
            "appearance": index % 3,
            "lock": generator.choice((9, 9, generator.randrange(9))),
            "capacity": generator.choice((4096, 65536)),
            "operations": [],
        }
        targets = (
            [0]
            + ([1] if value["light"] < 9 else [])
            + ([2] if value["dark"] < 9 else [])
        )
        for _ in range(generator.randrange(24)):
            kind = generator.randrange(7)
            value["operations"].append(
                dict(
                    target=generator.choice(targets),
                    kind=kind,
                    index=generator.randrange(15 if kind == 6 else 16),
                    color_kind=generator.randrange(3),
                    rgb=generator.getrandbits(24),
                    clear=bool(generator.randrange(4) == 0),
                    italic=bool(generator.getrandbits(1)),
                    bold=bool(generator.getrandbits(1)),
                )
            )
        yield value


def compare(cases, cpp, zig):
    payload = "".join(
        json.dumps(value, separators=(",", ":")) + "\n" for value in cases
    ).encode()
    left = subprocess.run(
        [str(zig)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    right = subprocess.run(
        [str(cpp)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    assert len(left) == len(right) == len(cases) * 3
    for index, (original, ported) in enumerate(zip(left, right)):
        if original != ported:
            raise RuntimeError(
                f"Theme mismatch at record {index // 3}, result {index % 3}: request={cases[index // 3]!r}, Zig={original!r}, C++={ported!r}"
            )
    return left


def main():
    parser = argparse.ArgumentParser(
        description="Compare complete theme queries, appearance resolution and UTF-8 inspection against original Zig sources"
    )
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    source = (root / "src/client/config/config_queries.zig").read_text()
    query = source.split(".theme => ", 1)[1].split(",\n        .gui =>", 1)[0]
    source = (root / "src/client/config/Snapshot.zig").read_text()
    resolve = (
        source.split("pub fn resolveTheme(", 1)[1].split("{", 1)[1].split("\n}", 1)[0]
    )
    zig = zig_probe.replace("__QUERY__", query).replace("__RESOLVE__", resolve)
    cases = list(records())
    with tempfile.TemporaryDirectory(prefix="telar-theme-query-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(zig)
        (work / "cellgrid.zig").write_text('pub const Color=@import("color").Color;\n')
        (work / "syntaxhl.zig").write_text('pub const Role=@import("role").Role;\n')
        subprocess.run(
            [
                sys.executable,
                str(root / "services/gui-cpp/tools/generate_themes.py"),
                str(root / "src/model/appearance/theme_support.zig"),
                str(work / "theme_presets.hpp"),
            ],
            check=True,
        )
        subprocess.run(
            [
                options.compiler,
                "-std=c++23",
                "-O2",
                "-I",
                str(work),
                "-I",
                str(root / "services/gui-cpp"),
                "-I",
                str(root / "services/runtime-cpp"),
                "-I",
                str(root / "services/desktop-mode"),
                str(work / "probe.cpp"),
                "-o",
                str(work / "cpp"),
            ],
            check=True,
        )
        subprocess.run(
            [
                "zig",
                "build-exe",
                "-O",
                "ReleaseSafe",
                "-lc",
                "--dep",
                "theme_support",
                "--dep",
                "color",
                "--dep",
                "appearance",
                f"-Mroot={work / 'probe.zig'}",
                "--dep",
                "cellgrid",
                "--dep",
                "syntaxhl",
                f"-Mtheme_support={root / 'src/model/appearance/theme_support.zig'}",
                "--dep",
                "color",
                f"-Mcellgrid={work / 'cellgrid.zig'}",
                "--dep",
                "role",
                f"-Msyntaxhl={work / 'syntaxhl.zig'}",
                f"-Mcolor={root / 'lib/cellgrid/Color.zig'}",
                f"-Mrole={root / 'lib/syntaxhl/role.zig'}",
                f"-Mappearance={root / 'src/model/state/HostAppearance.zig'}",
                f"-femit-bin={work / 'zig'}",
            ],
            check=True,
        )
        original = compare(cases, work / "cpp", work / "zig")
        edges = []
        for case, response in list(zip(cases, original[::3]))[::23]:
            if json.loads(response) == "WriteFailed":
                continue
            for capacity in (0, len(response) - 1, len(response), len(response) + 1):
                edges.append({**case, "capacity": capacity})
        bounded = compare(edges, work / "cpp", work / "zig")
        payload = b'{"utf8":true}\n'
        left = subprocess.run(
            [str(work / "zig")], input=payload, capture_output=True, check=True
        ).stdout
        right = subprocess.run(
            [str(work / "cpp")], input=payload, capture_output=True, check=True
        ).stdout
        assert left == right, (left, right)
    failures = sum(value == b'"WriteFailed"' for value in original + bounded)
    print(
        f"Matched {len(cases) + len(edges):,} theme query/appearance records byte-for-byte, including {failures:,} bounded failures; all 16,777,216 three-byte UTF-8 decisions matched"
    )


if __name__ == "__main__":
    main()
