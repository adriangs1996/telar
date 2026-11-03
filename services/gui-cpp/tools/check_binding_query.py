import argparse
import json
import random
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

cpp_probe = r"""

#include "config/action_descriptions.hpp"
#include "config/binding_query.hpp"
#include "config/command_tab_action.hpp"
#include "telar_config/command_tab_registry.hpp"
#include "telar_config/limit_notices.hpp"
#include "core/memory.hpp"
#include "input/action.hpp"
#include "input/configuration.hpp"
#include "telar_plugins/identity.hpp"
#include "tests/json_fixture.hpp"
#include "telar_base/text/json.hpp"
#include <array>
#include <charconv>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>
using namespace telar::gui;
using telar::gui::test::requiredJsonField;
using telar::runtime::JsonValue;

std::int64_t integer(const JsonValue &value, std::string_view name) {
  const auto text = requiredJsonField(value, name).encoded();
  std::int64_t result = 0;
  auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{}) {
    throw std::runtime_error{"Invalid oracle number"};
  }
  return result;
}

std::uint64_t wide(const JsonValue &value, std::string_view name) {
  const auto text = requiredJsonField(value, name).encoded();
  std::uint64_t result = 0;
  auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{}) {
    throw std::runtime_error{"Invalid oracle number"};
  }
  return result;
}

std::string bytes(const JsonValue &value) {
  std::string result;
  value.eachElement([&](const JsonValue &byte) {
    unsigned number = 0;
    const auto text = byte.encoded();
    std::from_chars(text.data(), text.data() + text.size(), number);
    result.push_back(static_cast<char>(number));
  });
  return result;
}

std::string text(const JsonValue &value) {
  SystemAllocator memory;
  String<SystemAllocator> decoded{AllocatorRef<char, SystemAllocator>{memory}};
  value.string(decoded);
  return {decoded.data(), decoded.size()};
}

BindingAction action(const JsonValue &request, ActionDescriptions<SystemAllocator> &descriptions, telar::runtime::config::RetainedCommandTabRegistry &commands) {
  const auto mode = integer(request, "mode");
  if (mode == 0) {
    const auto parsed = builtinBindingAction(text(requiredJsonField(request, "name")));
    if (!parsed) {
      throw std::runtime_error{"Unknown oracle action"};
    }
    return *parsed;
  }
  if (mode == 1) {
    constexpr std::array kinds{BindingActionKind::select_tab, BindingActionKind::select_workspace, BindingActionKind::select_tab_offset};
    return {.kind = kinds[integer(request, "numeric_kind")], .parameter = static_cast<std::int32_t>(integer(request, "parameter"))};
  }
  if (mode == 2 || mode == 3) {
    return {.kind = mode == 2 ? BindingActionKind::callback : BindingActionKind::expression, .parameter = static_cast<std::int32_t>(integer(request, "callback")), .generation = wide(request, "generation")};
  }
  ExtendedActionDescription description;
  if (mode == 4) {
    std::vector<std::string> owned;
    requiredJsonField(request, "argv").eachElement([&](const JsonValue &arg) {
      owned.push_back(bytes(arg));
    });
    std::vector<std::string_view> arguments;
    for (const auto &arg : owned) {
      arguments.push_back(arg);
    }
    auto label = bytes(requiredJsonField(request, "label"));
    telar::runtime::config::LimitNotices limits;
    const auto id = commands.keepReference(arguments, label, limits);
    if (!id) {
      throw std::runtime_error{"Missing oracle command"};
    }
    return commandTabAction(*id, wide(request, "generation"));
  } else if (mode == 5) {
    NotificationActionDescription value;
    value.title.assign(text(requiredJsonField(request, "title")));
    value.message.assign(text(requiredJsonField(request, "message")));
    value.level = static_cast<telar::NotificationLevel>(integer(request, "level"));
    value.duration_ms = integer(request, "duration");
    value.target = {.kind = static_cast<telar::NotificationTarget::Kind>(integer(request, "target_kind")), .id = wide(request, "target_id")};
    description = value;
  } else if (mode == 6 || mode == 7) {
    description = DefinitionActionDescription{.kind = mode == 6 ? DefinitionActionDescription::Kind::panel : DefinitionActionDescription::Kind::pick, .index = static_cast<std::uint8_t>(integer(request, "parameter"))};
  } else {
    description = PluginActionDescription{.plugin = telar::runtime::plugins::stableId(text(requiredJsonField(request, "plugin"))), .action = telar::runtime::plugins::stableId(text(requiredJsonField(request, "plugin_action")))};
  }
  return {.kind = BindingActionKind::extended, .parameter = descriptions.retain(description)};
}

void run(const JsonValue &request) {
  SystemAllocator memory;
  ActionDescriptions descriptions{memory};
  telar::runtime::config::RetainedCommandTabRegistry commands;
  InputConfiguration input;
  input.length = integer(request, "count");
  const auto index = integer(request, "index");
  if (static_cast<std::size_t>(index) < input.length) {
    auto &binding = input.configured[index];
    binding.prefixed = requiredJsonField(request, "prefixed").boolean();
    binding.action = action(request, descriptions, commands);
    requiredJsonField(request, "keys").eachElement([&](const JsonValue &value) {
      auto &key = binding.keys[binding.length++];
      key.key = static_cast<KeyChord::Key>(integer(value, "code"));
      key.modifiers = integer(value, "modifiers");
      const auto character = text(requiredJsonField(value, "text"));
      std::memcpy(&key.character, character.data(), character.size());
    });
  }
  std::array<char, 32768> output{};
  try {
    std::cout << BindingQuery::write(input, index, descriptions, commands, std::span{output}.first(integer(request, "capacity"))) << '\n';
  } catch (const std::exception &error) {
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
const keyinput = @import("keyinput");
const data = @import("model");
const core = @import("telar-core");
const Commands = @import("commands");
const Binding = keyinput.GenericBinding(data.Action, 5);
const Snapshot = struct { binding_count: usize, bindings: [256]Binding = undefined, bindings_prefixed: [256]bool = @splat(false), command_tabs: Commands = .{} };
const Query = struct { index: usize };
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn integer(value: std.json.Value, name: []const u8) !i64 {
    return std.fmt.parseInt(i64, value.object.get(name).?.number_string, 10);
}
fn wide(value: std.json.Value, name: []const u8) !u64 {
    return std.fmt.parseInt(u64, value.object.get(name).?.number_string, 10);
}
fn bytes(value: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    const items = value.array.items;
    const result = try allocator.alloc(u8, items.len);
    for (items, 0..) |item, index| {
        result[index] = try std.fmt.parseInt(u8, item.number_string, 10);
    }
    return result;
}
fn loadAction(request: std.json.Value, snapshot: *Snapshot, allocator: std.mem.Allocator) !data.Action {
    const mode = try integer(request, "mode");
    if (mode == 0) {
        return data.Action.parse(request.object.get("name").?.string);
    }
    if (mode == 1) {
        return switch (try integer(request, "numeric_kind")) {
            0 => .{ .select_tab = @intCast(try integer(request, "parameter")) },
            1 => .{ .select_workspace = @intCast(try integer(request, "parameter")) },
            else => .{ .select_tab_offset = @intCast(try integer(request, "parameter")) },
        };
    }
    if (mode == 2 or mode == 3) {
        const ref: @TypeOf(@as(data.Action, undefined).lua_callback) = .{ .generation = try wide(request, "generation"), .id = @as(u32, @intCast(try integer(request, "callback"))) };
        return if (mode == 2) .{ .lua_callback = ref } else .{ .lua_expr = ref };
    }
    if (mode == 4) {
        const items = request.object.get("argv").?.array.items;
        var arguments: [32][]const u8 = undefined;
        for (items, 0..) |item, index| {
            arguments[index] = try bytes(item, allocator);
        }
        const command = try data.CommandTab.init(arguments[0..items.len], try bytes(request.object.get("label").?, allocator));
        return .{ .command_tab = try snapshot.command_tabs.add(try wide(request, "generation"), &command) };
    }
    if (mode == 5) {
        const title = request.object.get("title").?.string;
        const message = request.object.get("message").?.string;
        var value: @TypeOf(@as(data.Action, undefined).notification) = .{ .title_len = @intCast(title.len), .message_len = @intCast(message.len), .level = @enumFromInt(try integer(request, "level")), .duration_ms = @intCast(try integer(request, "duration")) };
        @memcpy(value.title_bytes[0..title.len], title);
        @memcpy(value.message_bytes[0..message.len], message);
        value.target = switch (try integer(request, "target_kind")) {
            0 => .none,
            1 => .{ .pane = @enumFromInt(try wide(request, "target_id")) },
            2 => .{ .tab = @enumFromInt(try wide(request, "target_id")) },
            else => .{ .workspace = @enumFromInt(try wide(request, "target_id")) },
        };
        return .{ .notification = value };
    }
    if (mode == 6) {
        return .{ .open_panel = @intCast(try integer(request, "parameter")) };
    }
    if (mode == 7) {
        return .{ .pick = @intCast(try integer(request, "parameter")) };
    }
    return .{ .plugin = .{ .plugin = core.stableId(request.object.get("plugin").?.string), .action = core.stableId(request.object.get("plugin_action").?.string) } };
}
fn original(snapshot: *const Snapshot, query: Query, writer: *std.Io.Writer) !void {
    __BINDING__
}
__WRITE_ACTION__
fn run(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{ .parse_numbers = false });
    const request = parsed.value;
    var snapshot: Snapshot = .{ .binding_count = @intCast(try integer(request, "count")) };
    const index: usize = @intCast(try integer(request, "index"));
    if (index < snapshot.binding_count) {
        const items = request.object.get("keys").?.array.items;
        var keys: [5]keyinput.Key = undefined;
        for (items, 0..) |item, position| {
            var key: keyinput.Key = .plain(.tab);
            const tag: std.meta.Tag(keyinput.Key.Code) = @enumFromInt(try integer(item, "code"));
            switch (tag) {
                .char => key.code = .{ .char = .init(item.object.get("text").?.string) },
                inline else => |name| key.code = @unionInit(keyinput.Key.Code, @tagName(name), {}),
            }
            const mods = try integer(item, "modifiers");
            key.mods = .{ .ctrl = mods & 1 != 0, .alt = mods & 2 != 0, .shift = mods & 4 != 0, .super = mods & 8 != 0 };
            keys[position] = key;
        }
        snapshot.bindings[index] = try Binding.init(keys[0..items.len], try loadAction(request, &snapshot, allocator));
        snapshot.bindings_prefixed[index] = request.object.get("prefixed").?.bool;
    }
    var output: [32768]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output[0..@intCast(try integer(request, "capacity"))]);
    if (original(&snapshot, .{ .index = index }, &writer)) |_| {
        for (writer.buffered()) |byte| {
            _ = putchar(byte);
        }
    } else |err| {
        var text: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&text, "\"{s}\"", .{@errorName(err)});
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


model_exports = """
pub const Action = @import("input/action.zig").Action;
pub const CommandTab = @import("input/CommandTab.zig");
pub const CommandTabRef = @TypeOf(@as(Action, undefined).command_tab);
"""

core_exports = """
const types = @import("schema/types.zig");
pub const Limit = @import("Limit.zig");
pub const NotificationLevel = types.NotificationLevel;
pub const NotificationTarget = types.NotificationTarget;
pub const max_notification_title_bytes = types.max_notification_title_bytes;
pub const max_notification_message_bytes = types.max_notification_message_bytes;
pub const default_notification_duration_ms = types.default_notification_duration_ms;
pub const stableId = @import("plugin.zig").stableId;
"""


def binding_body(source):
    start = source.index(".binding => {") + len(".binding => {")
    depth = 1
    quote = None
    escaped = False
    for end in range(start, len(source)):
        byte = source[end]
        if quote:
            if escaped:
                escaped = False
            elif byte == "\\":
                escaped = True
            elif byte == quote:
                quote = None
            continue
        if byte in ('"', "'"):
            quote = byte
        elif byte == "{":
            depth += 1
        elif byte == "}":
            depth -= 1
            if depth == 0:
                return source[start:end]
    raise RuntimeError("Original binding query braces changed")


def records(root):
    generator = random.Random(0x42494E44)
    default = {
        "mode": 0,
        "name": "new-tab",
        "numeric_kind": 0,
        "parameter": 0,
        "callback": 0,
        "generation": 42,
        "count": 1,
        "index": 0,
        "capacity": 4096,
        "prefixed": False,
        "keys": [{"code": 0, "text": "s", "modifiers": 0}],
        "argv": [[101, 99, 104, 111]],
        "label": [],
        "title": "Ready",
        "message": "Message",
        "level": 0,
        "duration": 4000,
        "target_kind": 0,
        "target_id": 1,
        "plugin": "fixture",
        "plugin_action": "run",
    }
    source = (
        (root / "src/model/input/action.zig").read_text().split("pub fn parse(", 1)[1]
    )
    names = sorted(
        set(re.findall(r'"([a-z][a-z0-9-]+)"', source))
        - {"select-tab-", "select-workspace-"}
    )
    for name in names:
        yield {**default, "name": name}
    for executable in (
        b"/",
        b"///",
        b"/usr//bin/echo///",
        b"./echo",
        b"..",
        b"C:\\bin\\tool",
        "local/中".encode(),
        b"/local/\xff",
    ):
        for label in (b"", b"named", bytes(range(32)), b"\xff" * 32):
            yield {
                **default,
                "mode": 4,
                "argv": [list(executable)],
                "label": list(label),
            }
    for count, index in ((256, 255), (256, 256), (1, 1)):
        yield {**default, "count": count, "index": index}
    for kind in range(3):
        for parameter in (0, 1, 127, 128, 255) if kind < 2 else (-128, -1, 0, 1, 127):
            yield {**default, "mode": 1, "numeric_kind": kind, "parameter": parameter}
    for mode in (2, 3):
        for generation in (1, 2**63, 2**64 - 1):
            for callback in (0, 255, 511):
                yield {
                    **default,
                    "mode": mode,
                    "generation": generation,
                    "callback": callback,
                }
    for index in range(2048):
        mode = generator.randrange(9)
        value = {
            **default,
            "mode": mode,
            "capacity": generator.choice((4096, 32768)),
            "prefixed": bool(index & 1),
        }
        value["keys"] = [
            {
                "code": generator.randrange(15),
                "text": generator.choice(("s", "\0", "中", "🌱", "é")),
                "modifiers": generator.randrange(16),
            }
            for _ in range(generator.randrange(2 if value["prefixed"] else 1, 6))
        ]
        for key in value["keys"]:
            if key["code"] != 0:
                key["text"] = ""
        if mode == 0:
            value["name"] = generator.choice(names)
        elif mode == 1:
            value.update(
                numeric_kind=generator.randrange(3), parameter=generator.randrange(256)
            )
            value["parameter"] = (
                value["parameter"] - 128
                if value["numeric_kind"] == 2
                else value["parameter"]
            )
        elif mode in (2, 3):
            value.update(
                callback=generator.randrange(512), generation=generator.getrandbits(64)
            )
        elif mode == 4:
            value["argv"] = [
                list(
                    generator.choice(
                        ("echo", 'quoted "中', "a\\b", "\x01" * 64)
                    ).encode()
                )
                for _ in range(generator.randrange(1, 10))
            ]
            if index % 5 == 0:
                value["argv"] = [list(b"\\" * 4096)]
            if index % 7 == 0:
                value["argv"] = [list(b"echo"), [255, 128, 254]]
            value["label"] = list(generator.choice(("", "label", "中")).encode())
        elif mode == 5:
            value.update(
                title=generator.choice(("Ready", "é" * 48)),
                message=generator.choice(("", "中" * 170)),
                level=generator.randrange(4),
                duration=generator.randrange(500, 60001),
                target_kind=generator.randrange(4),
                target_id=generator.randrange(1, 2**64),
            )
        elif mode in (6, 7):
            value["parameter"] = generator.choice((0, 1, 15, 255))
        else:
            value.update(
                plugin=generator.choice(("fixture", "中", "")),
                plugin_action=generator.choice(("run", "x" * 128, "🌱")),
            )
        if index % 17 == 0:
            value.update(count=0, index=0)
        yield value


def compare(cases, cpp, zig):
    payload = "".join(
        json.dumps(case, ensure_ascii=True, separators=(",", ":")) + "\n"
        for case in cases
    ).encode()
    left = subprocess.run(
        [str(zig)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    right = subprocess.run(
        [str(cpp)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    assert len(left) == len(right) == len(cases)
    for index, (a, b) in enumerate(zip(left, right)):
        if a != b:
            raise RuntimeError(
                f"Binding mismatch {index}: request={cases[index]!r}, Zig={a!r}, C++={b!r}"
            )
    return left


def main():
    parser = argparse.ArgumentParser(
        description="Compare configured binding JSON with the original Zig action/key types and serializer"
    )
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    original = (root / "src/client/config/config_queries.zig").read_text()
    zig = zig_probe.replace("__BINDING__", binding_body(original)).replace(
        "__WRITE_ACTION__", original[original.index("fn writeAction(") :]
    )
    cases = list(records(root))
    with tempfile.TemporaryDirectory(prefix="telar-binding-query-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(zig)
        model_directory = work / "model_sources"
        core_directory = work / "core_sources"
        shutil.copytree(root / "src/model", model_directory)
        shutil.copytree(root / "src/core", core_directory)
        (model_directory / "oracle.zig").write_text(model_exports)
        (core_directory / "oracle.zig").write_text(core_exports)
        subprocess.run(
            [
                sys.executable,
                str(root / "services/gui-cpp/tools/generate_bindings.py"),
                str(root / "src/client/config/default_bindings.zig"),
                str(work / "default_bindings.hpp"),
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
                str(root / "dlls/telar-client/include"), "-I",
                str(root / "dlls/telar-base/include"), "-I",
                str(root / "dlls/telar-lua/include"), "-I",
                str(root / "dlls/telar-platform/include"), "-I",
                str(root / "dlls/telar-plugins/include"), "-I",
                str(root / "dlls/telar-config/include"),
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
                "keyinput",
                "--dep",
                "model",
                "--dep",
                "telar-core",
                "--dep",
                "commands",
                f"-Mroot={work / 'probe.zig'}",
                f"-Mkeyinput={root / 'lib/keyinput/root.zig'}",
                "--dep",
                "telar-core",
                f"-Mmodel={model_directory / 'oracle.zig'}",
                f"-Mtelar-core={core_directory / 'oracle.zig'}",
                "--dep",
                "telar-core",
                "--dep",
                "model",
                f"-Mcommands={root / 'src/client/config/CommandTabs.zig'}",
                f"-femit-bin={work / 'zig'}",
            ],
            check=True,
        )
        baseline = compare(cases, work / "cpp", work / "zig")
        edges = []
        for case, response in list(zip(cases, baseline))[::19]:
            if json.loads(response) in ("WriteFailed", "BindingNotFound"):
                continue
            for capacity in (0, len(response) - 1, len(response), len(response) + 1):
                edges.append({**case, "capacity": capacity})
        bounded = compare(edges, work / "cpp", work / "zig")
    failures = sum(value == b'"WriteFailed"' for value in baseline + bounded)
    print(
        f"Matched {len(cases) + len(edges):,} configured-binding records byte-for-byte, including {failures:,} bounded failures"
    )


if __name__ == "__main__":
    main()
