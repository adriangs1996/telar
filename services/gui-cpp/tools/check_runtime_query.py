import argparse
import json
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile


number_fields = {
    "graphics_pane_bytes": ("values.graphics.pane_bytes", "usize"),
    "graphics_global_bytes": ("values.graphics.global_bytes", "usize"),
    "proxy_capture_max_part_bytes": ("values.proxy.capture.part_bytes", "usize"),
    "proxy_capture_max_exchange_bytes": ("values.proxy.capture.exchange_bytes", "usize"),
    "proxy_capture_max_total_bytes": ("values.proxy.capture.total_bytes", "usize"),
    "proxy_capture_join_timeout_ms": ("values.proxy.capture.join_timeout", "u32"),
    "engine_idle_timeout_ms": ("values.engine.idle_timeout", "u32"),
}
boolean_fields = {
    "history_output_capture": "values.capture_output",
    "session_persist": "values.persist_session",
    "session_resume_agents": "values.resume_agents",
    "proxy_enabled": "values.proxy.enabled",
    "proxy_anonymous_tunnels": "values.proxy.anonymous_tunnels",
    "proxy_capture_enabled": "values.proxy.capture.enabled",
}
path_fields = {
    "history_path": "values.history_path",
    "session_path": "values.session_path",
    "proxy_ca_dir": "values.proxy.authority_directory",
}


cpp_probe = r'''
#include "config/query.hpp"
#include "config/runtime_query.hpp"
#include "config/runtime_values.hpp"
#include "core/memory.hpp"
#include "tests/json_fixture.hpp"
#include "text/json.hpp"
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

using namespace telar::gui;
using telar::gui::test::requiredJsonField;
using telar::runtime::JsonValue;
static_assert(std::endian::native == std::endian::little);

std::uint64_t number(const JsonValue &request, std::string_view name) {
  const auto text = requiredJsonField(request, name).encoded();
  std::uint64_t value = 0;
  const auto parsed = std::from_chars(text.data(), text.data()+text.size(), value);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data()+text.size()) {
    throw std::runtime_error{"Invalid oracle number"};
  }
  return value;
}

void serialize(const JsonValue &request) {
  SystemAllocator memory;
  telar::runtime::config::RuntimeValues values{memory};
  __LOAD_VALUES__
  requiredJsonField(request,"proxy_intercept_hosts").eachElement([&](const JsonValue &host) {
    String<SystemAllocator> text{AllocatorRef<char,SystemAllocator>{memory}};
    host.string(text);
    if (!values.proxy.intercept_hosts.append(text)) {
      throw std::runtime_error{"Invalid oracle host"};
    }
  });
  values.proxy.intercept_hosts.finish();
  const auto count = number(request,"agent_manifest_count");
  while (values.manifests.entries().size() < count) {
    values.manifests.add("fixture-" + std::to_string(values.manifests.entries().size()));
  }
  std::array<char,ConfigurationQuery::capacity> output{};
  try {
    std::cout << RuntimeQuery::write(values,output) << '\n';
  } catch (const std::length_error &error) {
    if (std::string_view{error.what()} != "WriteFailed") {
      throw;
    }
    std::cout << "\"WriteFailed\"\n";
  }
}

int main() {
  constexpr std::uint32_t maximum_record_bytes = 128*1024;
  std::uint32_t length = 0;
  while (std::cin.read(reinterpret_cast<char *>(&length),sizeof(length))) {
    if (length > maximum_record_bytes) {
      return 1;
    }
    std::string input(length,'\0');
    if (!std::cin.read(input.data(),length)) {
      return 1;
    }
    serialize(JsonValue::parse(input));
  }
  return std::cin.eof() && std::cin.gcount()==0 ? 0 : 1;
}
'''


zig_probe = r'''
const std = @import("std");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
const core = struct { const max_intercept_hosts = 256; };

const Runtime = struct {
    __FIELDS__
    agent_manifests: struct { count: usize },
    proxy_intercept_hosts: []const []const u8,
    fn historyPath(self: *const Runtime) ?[]const u8 {
        return if (self.history_path.len==0) null else self.history_path;
    }
    fn sessionPath(self: *const Runtime) ?[]const u8 {
        return if (self.session_path.len==0) null else self.session_path;
    }
    fn proxyCaDir(self: *const Runtime) ?[]const u8 {
        return if (self.proxy_ca_dir.len==0) null else self.proxy_ca_dir;
    }
    fn proxyInterceptHosts(self: *const Runtime, _: *[core.max_intercept_hosts][]const u8) []const []const u8 {
        return self.proxy_intercept_hosts;
    }
};
const Snapshot = struct { runtime: Runtime };

fn original(snapshot: *const Snapshot, writer: *std.Io.Writer) !void {
    __ORIGINAL__
}

fn number(request: std.json.Value, name: []const u8) !usize {
    return std.fmt.parseInt(usize,request.object.get(name).?.number_string,10);
}

fn run(source: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value,allocator,source,.{.parse_numbers=false});
    defer parsed.deinit();
    const request = parsed.value;
    const items = request.object.get("proxy_intercept_hosts").?.array.items;
    var hosts: [core.max_intercept_hosts][]const u8 = undefined;
    for (items,0..) |item,index| hosts[index]=item.string;
    const snapshot: Snapshot = .{.runtime=.{
        __LOAD_VALUES__
        .agent_manifests=.{.count=try number(request,"agent_manifest_count")},
        .proxy_intercept_hosts=hosts[0..items.len],
    }};
    var buffer: [__CAPACITY__]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    original(&snapshot,&writer) catch |err| {
        if (err != error.WriteFailed) return err;
        for ("\"WriteFailed\"\n") |byte| _ = putchar(byte);
        return;
    };
    for (writer.buffered()) |byte| _ = putchar(byte);
    _ = putchar('\n');
}

pub fn main() !void {
    var input: [128*1024]u8 = undefined;
    while (true) {
        const first = getchar();
        if (first<0) return;
        var length: u32 = @intCast(first);
        for (1..4) |index| {
            const byte = getchar();
            if (byte<0) return error.TruncatedInput;
            length |= @as(u32,@intCast(byte)) << @intCast(index*8);
        }
        if (length>input.len) return error.TooLarge;
        for (input[0..length]) |*byte| {
            const next = getchar();
            if (next<0) return error.TruncatedInput;
            byte.* = @intCast(next);
        }
        try run(input[0..length]);
    }
}
'''


def reference(root):
    source = (root / "src/client/config/config_queries.zig").read_text()
    start = source.index(".runtime => {") + len(".runtime => {")
    depth = 1
    for end in range(start, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            body = source[start:end]
            break
    else:
        raise RuntimeError("Runtime query reference has unbalanced braces")
    if "std.json.Stringify.value" not in body or "value.proxyInterceptHosts" not in body:
        raise RuntimeError("The runtime section extraction contract changed")
    command = (root / "src/core/schema/messages/ClientCommand.zig").read_text()
    capacity = re.search(r"pub const capacity = ([0-9]+);", command).group(1)
    fields = [f"{name}: {kind}," for name, (_, kind) in number_fields.items()]
    fields += [f"{name}: bool," for name in boolean_fields]
    fields += [f"{name}: []const u8," for name in path_fields]
    loaded = [f'.{name}=@intCast(try number(request,"{name}")),' for name in number_fields]
    loaded += [f'.{name}=request.object.get("{name}").?.bool,' for name in boolean_fields]
    loaded += [f'.{name}=request.object.get("{name}").?.string,' for name in path_fields]
    return (zig_probe.replace("__ORIGINAL__", body).replace("__FIELDS__", "\n".join(fields))
            .replace("__LOAD_VALUES__", "\n".join(loaded)).replace("__CAPACITY__", capacity))


def candidate():
    loaded = []
    for name, (destination, _) in number_fields.items():
        value = f'number(request,"{name}")'
        if name.endswith("_timeout_ms"):
            value = f'std::chrono::milliseconds{{{value}}}'
        loaded.append(f"{destination}={value};")
    loaded += [f'{destination}=requiredJsonField(request,"{name}").boolean();'
               for name, destination in boolean_fields.items()]
    loaded += [f'requiredJsonField(request,"{name}").string({destination});'
               for name, destination in path_fields.items()]
    return cpp_probe.replace("__LOAD_VALUES__", "\n".join(loaded))


def records():
    randomizer = random.Random(0xC0F16)
    texts = ("", "relative.db", "/path with spaces/é中😀", "\\" * 1024, '"' * 1024, "line\nnext\tvalue", "\u0085\u2028")
    for index in range(4096):
        record = {name: randomizer.choice((0, 1, 2**64 - 1, randomizer.randrange(2**32)))
                  for name, (_, kind) in number_fields.items() if kind == "usize"}
        record.update({name: randomizer.randrange(2**32) for name, (_, kind) in number_fields.items() if kind == "u32"})
        record.update({name: randomizer.choice((True, False)) for name in boolean_fields})
        record.update({name: randomizer.choice(texts) for name in path_fields})
        record["agent_manifest_count"] = randomizer.randrange(5, 33)
        count = randomizer.choice((0, 1, 8, 32, 128, 256))
        record["proxy_intercept_hosts"] = sorted(f"host-{index}-{item}.test" for item in range(count))
        yield record

    base = {
        "graphics_pane_bytes": 16 * 1024 * 1024, "graphics_global_bytes": 32 * 1024 * 1024,
        "proxy_capture_max_part_bytes": 1024 * 1024, "proxy_capture_max_exchange_bytes": 2 * 1024 * 1024,
        "proxy_capture_max_total_bytes": 4 * 1024 * 1024, "proxy_capture_join_timeout_ms": 1000,
        "engine_idle_timeout_ms": 300000, "agent_manifest_count": 5, "proxy_intercept_hosts": [],
        **{name: False for name in boolean_fields}, **{name: "" for name in path_fields},
    }
    for character in ('\b', '\f', '\n', '\r', '\t'):
        for length in (1, 31, 128, 256, 512, 1024):
            yield {**base, **{name: character * length for name in path_fields}}


def main():
    parser = argparse.ArgumentParser(description="Compare bounded runtime-section JSON with the original Zig serializer")
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    cases = list(records())
    requests = [json.dumps(record, ensure_ascii=False, separators=(",", ":")).encode() for record in cases]
    payload = b"".join(struct.pack("<I", len(record)) + record for record in requests)
    with tempfile.TemporaryDirectory(prefix="telar-runtime-query-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(candidate())
        (work / "probe.zig").write_text(reference(root))
        subprocess.run([options.compiler, "-std=c++23", "-O2", "-I", str(root / "services/gui-cpp"), "-I", str(root / "services/runtime-cpp"), "-I", str(root / "dlls/telar-client/include"), str(work / "probe.cpp"), "-o", str(work / "cpp")], check=True)
        subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc", str(work / "probe.zig"), f"-femit-bin={work / 'zig'}"], check=True)
        expected = subprocess.run([str(work / "zig")], input=payload, capture_output=True, check=True).stdout.split(b"\n")[:-1]
        actual = subprocess.run([str(work / "cpp")], input=payload, capture_output=True, check=True).stdout.split(b"\n")[:-1]
        if len(expected) != len(cases) or len(actual) != len(cases):
            raise RuntimeError("Runtime query probe record count differs")
        failures = 0
        for index, (baseline, ported) in enumerate(zip(expected, actual)):
            left, right = json.loads(baseline), json.loads(ported)
            if left != right:
                raise RuntimeError(f"Runtime query mismatch at {index}: request={cases[index]!r}, C++={right!r}, Zig={left!r}")
            if baseline != ported:
                raise RuntimeError(f"Runtime query bytes differ at {index}: C++={ported!r}, Zig={baseline!r}")
            failures += left == "WriteFailed"
    print(f"Matched {len(cases):,} typed runtime-section JSON records byte-for-byte against the extracted Zig serializer, including {failures:,} bounded failures")


if __name__ == "__main__":
    main()
