import argparse
import json
import random
import shutil
import subprocess
import tempfile
from pathlib import Path

from check_binding_query import core_exports, model_exports

cpp_probe = r"""

#include "config/command_tab_reference.hpp"
#include "config/command_tab_registry.hpp"
#include "config/command_tab_view.hpp"
#include "config/limit_notices.hpp"
#include "core/json_writer.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "tests/json_fixture.hpp"
#include "text/json.hpp"
#include <array>
#include <charconv>
#include <cstdint>
#include <iostream>
#include <optional>
#include <string>
#include <vector>
using namespace telar::gui;
using namespace telar::runtime::config;
using telar::gui::test::requiredJsonField;
using telar::runtime::JsonValue;
std::optional<RetainedCommandTabRegistry> commands{std::in_place};
std::vector<std::optional<CommandTabReference>> handles;

std::uint64_t number(const JsonValue &value) {
  const auto encoded = value.encoded();
  std::uint64_t result = 0;
  if (std::from_chars(encoded.data(), encoded.data() + encoded.size(), result).ec != std::errc{}) {
    throw std::runtime_error{"Invalid oracle number"};
  }
  return result;
}

std::string bytes(const JsonValue &value) {
  std::string result;
  value.eachElement([&](const JsonValue &item) {
    result.push_back(static_cast<char>(number(item)));
  });
  return result;
}

void writeReference(JsonWriter &writer, const std::optional<CommandTabReference> &reference) {
  if (!reference) {
    writer.value(nullptr);
    return;
  }
  writer.object([&](JsonWriter &value) {
    value.member("id", reference->id);
    value.member("epoch", reference->epoch);
  });
}

void writeCommand(JsonWriter &writer, const std::optional<CommandTabView> &command) {
  if (!command) {
    writer.value(nullptr);
    return;
  }
  writer.object([&](JsonWriter &value) {
    value.member("label", [&](JsonWriter &label) {
      label.bytes(telar::byteView(command->label()));
    });
    value.member("argv", [&](JsonWriter &arguments) {
      arguments.array([&](JsonWriter &items) {
        for (const auto argument : command->argv()) {
          items.element([&](JsonWriter &item) {
            item.bytes(telar::byteView(argument));
          });
        }
      });
    });
  });
}

void run(const JsonValue &request) {
  const auto operation = requiredJsonField(request, "op");
  std::optional<CommandTabReference> reference;
  std::optional<CommandTabView> command;
  std::optional<telar::LimitReach> limit;
  LimitNotices limits;
  if (operation.equals("reset")) {
    commands.emplace();
    handles.clear();
  } else if (operation.equals("seal")) {
    commands->seal();
  } else if (operation.equals("begin")) {
    commands->beginRender();
  } else if (operation.equals("end")) {
    commands->endRender();
  } else if (operation.equals("keep")) {
    std::vector<std::string> owned;
    requiredJsonField(request, "argv").eachElement([&](const JsonValue &item) {
      owned.push_back(bytes(item));
    });
    std::vector<std::string_view> arguments;
    for (const auto &argument : owned) {
      arguments.push_back(argument);
    }
    const auto label = bytes(requiredJsonField(request, "label"));
    reference = commands->keepReference(arguments, label, limits);
    handles.push_back(reference);
    if (!limits.entries().empty()) {
      limit = limits.entries().front();
    }
  } else if (operation.equals("load")) {
    const auto handle = number(requiredJsonField(request, "handle"));
    if (handle < handles.size()) {
      reference = handles[handle];
    }
    if (reference) {
      const auto id = requiredJsonField(request, "id");
      const auto epoch = requiredJsonField(request, "epoch");
      if (id.encoded() != "null") {
        reference->id = static_cast<std::uint16_t>(number(id));
      }
      if (epoch.encoded() != "null") {
        reference->epoch = static_cast<std::uint32_t>(number(epoch));
      }
      command = commands->load(*reference);
    }
  } else {
    throw std::runtime_error{"Unknown oracle operation"};
  }
  const auto state = commands->checkpoint();
  std::array<char, 65536> output{};
  JsonWriter writer{output};
  writer.object([&](JsonWriter &value) {
    value.member("count", state.rows);
    value.member("used", state.bytes);
    value.member("reference", [&](JsonWriter &item) {
      writeReference(item, reference);
    });
    value.member("command", [&](JsonWriter &item) {
      writeCommand(item, command);
    });
    value.member("limit", [&](JsonWriter &item) {
      if (limit) {
        item.object([&](JsonWriter &record) {
          record.member("name", limit->name);
          record.member("noun", limit->noun);
          record.member("value", limit->value);
        });
      } else {
        item.value(nullptr);
      }
    });
  });
  std::cout << writer.view() << '\n';
}

int main() {
  for (std::string line; std::getline(std::cin, line);) {
    run(JsonValue::parse(line));
  }
}
"""

zig_probe = r"""
const std = @import("std");
const data = @import("model");
const Commands = @import("commands");
const core = @import("telar-core");
var commands: Commands = .{};
var handles: std.ArrayList(?data.CommandTabRef) = .empty;
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn number(value: std.json.Value) !u64 {
    return std.fmt.parseInt(u64, value.number_string, 10);
}
fn bytes(value: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    const result = try allocator.alloc(u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        result[index] = @intCast(try number(item));
    }
    return result;
}
fn run(source: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{ .parse_numbers = false });
    const request = parsed.value;
    const operation = request.object.get("op").?.string;
    var reference: ?data.CommandTabRef = null;
    var command: data.CommandTab = undefined;
    var loaded = false;
    var limit: ?core.Limit = null;
    if (std.mem.eql(u8, operation, "reset")) {
        commands = .{};
        handles.clearRetainingCapacity();
    } else if (std.mem.eql(u8, operation, "seal")) {
        commands.seal();
    } else if (std.mem.eql(u8, operation, "begin")) {
        commands.beginRender();
    } else if (std.mem.eql(u8, operation, "end")) {
        commands.endRender();
    } else if (std.mem.eql(u8, operation, "keep")) {
        const items = request.object.get("argv").?.array.items;
        var arguments: [32][]const u8 = undefined;
        for (items, 0..) |item, index| {
            arguments[index] = try bytes(item, allocator);
        }
        const value = try data.CommandTab.init(arguments[0..items.len], try bytes(request.object.get("label").?, allocator));
        reference = commands.add(42, &value) catch null;
        if (reference == null) {
            limit = if (commands.sealed) Commands.recent_limit else if (commands.fixedRowsFull()) Commands.rows_limit else Commands.bytes_limit;
        }
        try handles.append(std.heap.page_allocator, reference);
    } else if (std.mem.eql(u8, operation, "load")) {
        const handle = try number(request.object.get("handle").?);
        if (handle < handles.items.len) {
            reference = handles.items[handle];
        }
        if (reference) |*ref| {
            const id = request.object.get("id").?;
            const epoch = request.object.get("epoch").?;
            if (id != .null) {
                ref.id = @intCast(try number(id));
            }
            if (epoch != .null) {
                ref.epoch = @intCast(try number(epoch));
            }
            loaded = commands.load(ref.*, &command);
        }
    } else {
        return error.UnknownOperation;
    }
    var output: [65536]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try writer.print("{{\"count\":{d},\"used\":{d},\"reference\":", .{ commands.count, commands.used });
    if (reference) |ref| {
        try std.json.Stringify.value(.{ .id = ref.id, .epoch = ref.epoch }, .{}, &writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"command\":");
    if (loaded) {
        var arguments: [32][]const u8 = undefined;
        for (0..command.argument_count) |index| {
            arguments[index] = command.argument(index);
        }
        try std.json.Stringify.value(.{ .label = command.label(), .argv = arguments[0..command.argument_count] }, .{}, &writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"limit\":");
    try std.json.Stringify.value(limit, .{}, &writer);
    try writer.writeByte('}');
    for (writer.buffered()) |byte| {
        _ = putchar(byte);
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


def keep(arguments, label=b""):
    return {
        "op": "keep",
        "argv": [list(argument) for argument in arguments],
        "label": list(label),
    }


def load(handle, epoch=None, identity=None):
    return {"op": "load", "handle": handle, "id": identity, "epoch": epoch}


def records():
    yield {"op": "reset"}
    for index in range(770):
        yield keep([b"echo", str(index).encode()])
    yield keep([b"echo", b"0"])
    yield {"op": "seal"}
    for index in range(260):
        yield keep([b"echo", str(1000 + index).encode()])
    for handle in (0, 767, 768, 770, 771, 1025):
        yield load(handle)
    yield load(0, epoch=1)
    yield load(0, identity=65535)
    yield {"op": "reset"}
    for index in range(21):
        yield keep([b"x" * 128] * 32, str(index).encode().rjust(32, b"0"))
    yield {"op": "seal"}
    for index in range(40):
        yield keep([b"y" * 128] * 32, str(index + 100).encode().rjust(32, b"0"))
        if index % 4 == 0:
            yield load(0)
            yield load(21)
    yield {"op": "begin"}
    for index in range(50):
        yield keep([b"z" * 4096], str(index).encode())
    yield load(61)
    yield {"op": "end"}
    yield {"op": "begin"}
    yield load(61)
    yield {"op": "end"}
    generator = random.Random(0x434D4454)
    for cycle in range(8):
        yield {"op": "reset"}
        count = 0
        for index in range(generator.randrange(12, 60)):
            yield keep([b"fixed", str(index).encode()])
            count += 1
        yield {"op": "seal"}
        for index in range(512):
            operation = generator.randrange(10)
            if operation < 6:
                total = generator.choice((16, 512, 2000, 4096))
                argument = bytes(generator.randrange(1, 256) for _ in range(total))
                yield keep([argument], str(cycle * 1000 + index).encode())
                count += 1
            elif operation < 8:
                yield load(
                    generator.randrange(count), epoch=0 if index % 31 == 0 else None
                )
            else:
                yield {"op": "begin" if operation == 8 else "end"}


def main():
    parser = argparse.ArgumentParser(
        description="Compare packed command storage, recent references and render admission with the original Zig pool"
    )
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    cases = list(records())
    with tempfile.TemporaryDirectory(prefix="telar-command-tabs-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp_probe)
        (work / "probe.zig").write_text(zig_probe)
        model = work / "model_sources"
        core = work / "core_sources"
        shutil.copytree(root / "src/model", model)
        shutil.copytree(root / "src/core", core)
        (model / "oracle.zig").write_text(model_exports)
        (core / "oracle.zig").write_text(core_exports)
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
                str(root / "dlls/telar-client/include"),
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
                "model",
                "--dep",
                "commands",
                "--dep",
                "telar-core",
                f"-Mroot={work / 'probe.zig'}",
                "--dep",
                "telar-core",
                f"-Mmodel={model / 'oracle.zig'}",
                f"-Mtelar-core={core / 'oracle.zig'}",
                "--dep",
                "model",
                "--dep",
                "telar-core",
                f"-Mcommands={root / 'src/client/config/CommandTabs.zig'}",
                f"-femit-bin={work / 'zig'}",
            ],
            check=True,
        )
        payload = "".join(
            json.dumps(case, separators=(",", ":")) + "\n" for case in cases
        ).encode()
        expected = subprocess.run(
            [str(work / "zig")], input=payload, capture_output=True, check=True
        ).stdout.splitlines()
        actual = subprocess.run(
            [str(work / "cpp")], input=payload, capture_output=True, check=True
        ).stdout.splitlines()
        assert len(expected) == len(actual) == len(cases)
        for index, (left, right) in enumerate(zip(expected, actual)):
            if left != right:
                raise RuntimeError(
                    f"Command pool mismatch {index}: request={cases[index]!r}, Zig={left!r}, C++={right!r}"
                )
    refusals = sum(json.loads(value)["limit"] is not None for value in actual)
    print(
        f"Matched {len(cases):,} command-pool transitions byte-for-byte, including {refusals:,} bounded refusals"
    )


if __name__ == "__main__":
    main()
