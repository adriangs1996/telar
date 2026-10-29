import argparse
import json
import random
import shutil
import subprocess
import tempfile
from pathlib import Path

cpp_probe = r"""

#include "config/client_query.hpp"
#include "tests/json_fixture.hpp"
#include "text/json.hpp"
#include <array>
#include <charconv>
#include <cstdint>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
using namespace telar::gui;
using telar::gui::test::requiredJsonField;
using telar::runtime::JsonValue;

std::uint64_t number(const JsonValue &request, std::string_view name) {
  const auto encoded = requiredJsonField(request, name).encoded();
  std::uint64_t result = 0;
  const auto parsed = std::from_chars(encoded.data(), encoded.data() + encoded.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != encoded.data() + encoded.size()) {
    throw std::runtime_error{"Invalid oracle number"};
  }

  return result;
}

std::string bytes(const JsonValue &value) {
  std::string result;
  value.eachElement([&](const JsonValue &byte) {
    const auto encoded = byte.encoded();
    unsigned number = 0;
    std::from_chars(encoded.data(), encoded.data() + encoded.size(), number);
    result.push_back(static_cast<char>(number));
  });

  return result;
}

std::optional<std::string> nullableBytes(const JsonValue &value) {
  return value.encoded() == "null" ? std::nullopt : std::optional{bytes(value)};
}

void run(const JsonValue &request) {
  const auto source = nullableBytes(requiredJsonField(request, "source"));
  const auto profile = nullableBytes(requiredJsonField(request, "profile"));
  const auto title = bytes(requiredJsonField(request, "window_title"));
  Configuration configuration;
  configuration.sound = {.enabled = requiredJsonField(request, "sound_enabled").boolean(),
                         .ready = requiredJsonField(request, "sound_ready").boolean(),
                         .needs_input = requiredJsonField(request, "sound_needs_input").boolean()};
  configuration.notification_delivery = requiredJsonField(request, "system_delivery").boolean() ? NotificationDelivery::system : NotificationDelivery::telar;
  configuration.history = {.show_agent_commands = requiredJsonField(request, "history_show_agent_commands").boolean(),
                           .enter_runs = requiredJsonField(request, "history_enter_runs").boolean(),
                           .match_fts = requiredJsonField(request, "history_match_fts").boolean()};
  ClientQueryContext context{
      .source = source ? std::optional<std::string_view>{*source} : std::nullopt,
      .profile = profile ? std::optional<std::string_view>{*profile} : std::nullopt,
      .generation = number(request, "generation"),
      .view = {.sidebar_visible = requiredJsonField(request, "sidebar_visible").boolean(),
               .sidebar_width = static_cast<std::uint16_t>(number(request, "sidebar_width")),
               .workspace_list_collapsed = requiredJsonField(request, "workspace_list_collapsed").boolean(),
               .pane_gaps = requiredJsonField(request, "pane_gaps").boolean(),
               .window_title = title}};
  std::array<char, 32768> output{};
  try {
    std::cout << ClientQuery::write(configuration, context, std::span{output}.first(number(request, "capacity"))) << '\n';
  } catch (const std::length_error &error) {
    std::cout << '"' << error.what() << '"' << '\n';
  }
}

int main() {
  for (std::string line; std::getline(std::cin, line);) {
    run(JsonValue::parse(line));
  }
}
"""

zig_probe = r"""
const std = @import("std");
const SoundPolicy = @import("sound");
const Delivery = @import("delivery").NotificationDelivery;
const Snapshot = struct {
    sound: SoundPolicy = .{},
    notification_delivery: Delivery = .telar,
    history_show_agent_commands: bool = false,
    history_enter_runs: bool = false,
    history_match_fts: bool = false,
};
const Generation = struct { snapshot: Snapshot };
const ClientModel = struct {
    configuration_generation: u64,
    sidebar_visible: bool,
    sidebar_width: u16,
    workspace_list_collapsed: bool,
    pane_gaps: bool,
    window_title_template: [128]u8 = undefined,
    window_title_template_len: u8 = 0,
};
const Options = struct { config_path: ?[]const u8, profile: ?[]const u8 };
const Client = struct { options: Options, model: ClientModel, lua_generation: *const Generation };
const original_title = windowTitleTemplate;
const data = struct {
    const config_reload = struct {
        const windowTitleTemplate = original_title;
    };
};
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;

fn number(request: std.json.Value, name: []const u8) !u64 {
    return std.fmt.parseInt(u64, request.object.get(name).?.number_string, 10);
}

fn flag(request: std.json.Value, name: []const u8) bool {
    return request.object.get(name).?.bool;
}

fn bytes(value: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    const result = try allocator.alloc(u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        result[index] = try std.fmt.parseInt(u8, item.number_string, 10);
    }

    return result;
}

fn nullableBytes(value: std.json.Value, allocator: std.mem.Allocator) !?[]const u8 {
    return if (value == .null) null else try bytes(value, allocator);
}

__TITLE_FUNCTION__

fn original(client: *const Client, output: []u8) !usize {
    const generation = client.lua_generation;
    var writer: std.Io.Writer = .fixed(output);
    __CLIENT_BODY__
    return writer.buffered().len;
}

fn run(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{ .parse_numbers = false });
    const request = parsed.value;
    const generation: Generation = .{ .snapshot = .{
        .sound = .{ .enabled = flag(request, "sound_enabled"), .ready = flag(request, "sound_ready"), .needs_input = flag(request, "sound_needs_input") },
        .notification_delivery = if (flag(request, "system_delivery")) .system else .telar,
        .history_show_agent_commands = flag(request, "history_show_agent_commands"),
        .history_enter_runs = flag(request, "history_enter_runs"),
        .history_match_fts = flag(request, "history_match_fts"),
    } };
    var client: Client = .{
        .options = .{ .config_path = try nullableBytes(request.object.get("source").?, allocator), .profile = try nullableBytes(request.object.get("profile").?, allocator) },
        .model = .{
            .configuration_generation = try number(request, "generation"),
            .sidebar_visible = flag(request, "sidebar_visible"),
            .sidebar_width = @intCast(try number(request, "sidebar_width")),
            .workspace_list_collapsed = flag(request, "workspace_list_collapsed"),
            .pane_gaps = flag(request, "pane_gaps"),
        },
        .lua_generation = &generation,
    };
    const title = try bytes(request.object.get("window_title").?, allocator);
    @memcpy(client.model.window_title_template[0..title.len], title);
    client.model.window_title_template_len = @intCast(title.len);
    var output: [32768]u8 = undefined;
    if (original(&client, output[0..@intCast(try number(request, "capacity"))])) |length| {
        for (output[0..length]) |byte| {
            _ = putchar(byte);
        }
    } else |err| {
        var encoded: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&encoded, "\"{s}\"", .{@errorName(err)});
        for (message) |byte| {
            _ = putchar(byte);
        }
    }

    _ = putchar('\n');
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
    generator = random.Random(0x434C4945)
    default = {
        "source": None,
        "profile": None,
        "generation": 1,
        "sidebar_visible": True,
        "sidebar_width": 42,
        "workspace_list_collapsed": False,
        "pane_gaps": True,
        "window_title": [],
        "sound_enabled": True,
        "sound_ready": True,
        "sound_needs_input": True,
        "system_delivery": False,
        "history_show_agent_commands": False,
        "history_enter_runs": False,
        "history_match_fts": False,
        "capacity": 4096,
    }
    yield default
    for path in (
        None,
        b"",
        b"./config.lua",
        "配置.lua".encode(),
        bytes(range(256)),
        b"\x01" * 4096,
    ):
        for profile in (None, b"", b"chosen", "選択".encode(), b"\xff"):
            for capacity in (4096, 32768):
                yield {
                    **default,
                    "source": None if path is None else list(path),
                    "profile": None if profile is None else list(profile),
                    "capacity": capacity,
                }
    for generation in (0, 1, 2**32, 2**63, 2**64 - 1):
        for width in (0, 1, 41, 42, 43, 65535):
            yield {**default, "generation": generation, "sidebar_width": width}
    flags = [name for name, value in default.items() if isinstance(value, bool)]
    for mask in range(1 << len(flags)):
        yield {
            **default,
            **{name: bool(mask & (1 << bit)) for bit, name in enumerate(flags)},
        }
    for index in range(1024):
        title = generator.choice(
            (
                "",
                "{workspace} {tab} {pane_title} {hostname}",
                "é" * 64,
                "中" * 42,
                'quoted "\\',
            )
        )
        path = generator.choice(
            (
                None,
                b"",
                bytes(
                    generator.randrange(256) for _ in range(generator.randrange(512))
                ),
                "relative/配置.lua".encode(),
            )
        )
        yield {
            **default,
            **{name: bool(generator.getrandbits(1)) for name in flags},
            "source": None if path is None else list(path),
            "profile": list(generator.choice(("", "chosen", "中")).encode()),
            "generation": generator.getrandbits(64),
            "sidebar_width": generator.randrange(65536),
            "window_title": list(title.encode()),
            "capacity": generator.choice((4096, 32768)),
        }


def compare(cases, cpp, zig):
    payload = "".join(
        json.dumps(case, separators=(",", ":")) + "\n" for case in cases
    ).encode()
    expected = subprocess.run(
        [str(zig)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    actual = subprocess.run(
        [str(cpp)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    assert len(expected) == len(actual) == len(cases)
    for index, (left, right) in enumerate(zip(expected, actual)):
        if left != right:
            raise RuntimeError(
                f"Client mismatch {index}: request={cases[index]!r}, Zig={left!r}, C++={right!r}"
            )
    return expected


def main():
    parser = argparse.ArgumentParser(
        description="Compare client configuration JSON with the original Zig serializer and policy types"
    )
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    adoption = (root / "src/client/config/config_adoption.zig").read_text()
    begin = adoption.index("    if (section == .client) {") + len(
        "    if (section == .client) {"
    )
    body = adoption[begin : adoption.index("    } else {", begin)]
    title_source = (root / "src/model/config/config_reload.zig").read_text()
    title = title_source[title_source.index("pub fn windowTitleTemplate(") :]
    cases = list(records())
    with tempfile.TemporaryDirectory(prefix="telar-client-query-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(
            zig_probe.replace("__CLIENT_BODY__", body).replace(
                "__TITLE_FUNCTION__", title
            )
        )
        core = work / "core_sources"
        shutil.copytree(root / "src/core", core)
        (core / "oracle.zig").write_text(
            'pub const AgentSound = @import("schema/types.zig").AgentSound;\n'
        )
        subprocess.run(
            [
                options.compiler,
                "-std=c++23",
                "-O2",
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
                "sound",
                "--dep",
                "delivery",
                f"-Mroot={work / 'probe.zig'}",
                "--dep",
                "telar-core",
                f"-Msound={root / 'src/model/config/SoundPolicy.zig'}",
                f"-Mdelivery={root / 'src/model/notifications/NotificationDelivery.zig'}",
                f"-Mtelar-core={core / 'oracle.zig'}",
                f"-femit-bin={work / 'zig'}",
            ],
            check=True,
        )
        baseline = compare(cases, work / "cpp", work / "zig")
        edges = []
        for case, response in list(zip(cases, baseline))[::13]:
            if response == b'"WriteFailed"':
                continue
            edges.extend(
                {**case, "capacity": capacity}
                for capacity in (0, len(response) - 1, len(response), len(response) + 1)
            )
        bounded = compare(edges, work / "cpp", work / "zig")
    failures = sum(value == b'"WriteFailed"' for value in baseline + bounded)
    print(
        f"Matched {len(cases) + len(edges):,} client query records byte-for-byte, including {failures:,} bounded failures"
    )


if __name__ == "__main__":
    main()
