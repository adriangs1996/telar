import argparse
import json
import math
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import tempfile


float_fields = {
    "size": "font.size",
    "line_height": "font.line_height",
    "letter_spacing": "font.letter_spacing",
    "opacity": "background_opacity",
    "padding_x": "padding_x",
    "padding_y": "padding_y",
    "chrome_scale": "chrome_scale",
    "sidebar_width": "sidebar_width",
}
zig_float_fields = {
    **float_fields,
    "opacity": "window.background_opacity",
    "padding_x": "window.padding.x",
    "padding_y": "window.padding.y",
    "chrome_scale": "chrome.scale",
    "sidebar_width": "sidebar.width",
}

cpp_probe = r"""
#include "config/gui_query.hpp"
#include "config/input_query.hpp"
#include "config/query.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "tests/json_fixture.hpp"
#include "telar_base/text/json.hpp"
#include <array>
#include <bit>
#include <charconv>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
using namespace telar::gui;
using telar::gui::test::requiredJsonField;
using telar::runtime::JsonValue;

std::uint64_t number(const JsonValue &request, std::string_view name) {
  const auto text = requiredJsonField(request, name).encoded();
  std::uint64_t result = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{}) {
    throw std::runtime_error{"Invalid oracle input"};
  }
  return result;
}

void run(const JsonValue &request) {
  SystemAllocator memory;
  std::array<char, ConfigurationQuery::capacity> storage{};
  auto output = std::span{storage}.first(number(request, "capacity"));
  try {
    if (number(request, "section") == 0) {
      Configuration configuration;
      __LOAD_FLOATS__
      String<SystemAllocator> family{AllocatorRef<char, SystemAllocator>{memory}};
      String<SystemAllocator> style{AllocatorRef<char, SystemAllocator>{memory}};
      requiredJsonField(request, "family").string(family);
      requiredJsonField(request, "style").string(style);
      configuration.font.family.assign(family);
      configuration.font.style.assign(style);
      configuration.font.thicken = requiredJsonField(request, "thicken").boolean();
      configuration.font.thicken_strength = number(request, "strength");
      configuration.cursor = static_cast<telar::CursorShape>(number(request, "cursor") + 1);
      configuration.cursor_blink = requiredJsonField(request, "blink").boolean();
      configuration.blink_interval = std::chrono::milliseconds{number(request, "blink_ms")};
      configuration.background_blur = number(request, "blur");
      if (number(request, "titlebar") != 0) {
        configuration.titlebar = number(request, "titlebar") == 2;
      }
      std::cout << GuiQuery::write(configuration, output, requiredJsonField(request, "native_titlebar").boolean());
    } else {
      InputConfiguration input;
      input.prefix.key = static_cast<KeyChord::Key>(number(request, "code"));
      input.prefix.modifiers = number(request, "modifiers");
      String<SystemAllocator> text{AllocatorRef<char, SystemAllocator>{memory}};
      requiredJsonField(request, "text").string(text);
      std::memcpy(&input.prefix.character, text.data(), text.size());
      input.sequence_timeout_ns = number(request, "timeout");
      input.length = number(request, "bindings");
      std::cout << InputQuery::write(input, output);
    }
  } catch (const std::length_error &error) {
    if (std::string_view{error.what()} != "WriteFailed") {
      throw;
    }
    std::cout << "\"WriteFailed\"";
  }
  std::cout << '\n';
}

int main() {
  for (std::string line; std::getline(std::cin, line);) {
    run(JsonValue::parse(line));
  }
}
"""

zig_probe = r"""
const std=@import("std");
const GuiConfig=@import("gui_config");
const Key=@import("key");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
const Snapshot=struct { gui:GuiConfig=.{} , prefix:Key=.plain(.tab), input_sequence_timeout_ns:u64=0, binding_count:u16=0 };
fn originalGui(snapshot:*const Snapshot,writer:*std.Io.Writer) !void { __GUI_BODY__ }
fn originalInput(snapshot:*const Snapshot,writer:*std.Io.Writer) !void { __INPUT_BODY__; }
fn number(request:std.json.Value,name:[]const u8) !u64 { return std.fmt.parseInt(u64,request.object.get(name).?.number_string,10); }
fn run(source:[]const u8) !void {
  const parsed=try std.json.parseFromSlice(std.json.Value,std.heap.page_allocator,source,.{.parse_numbers=false});
  defer parsed.deinit();
  const request=parsed.value;
  var snapshot:Snapshot=.{};
  __LOAD_FLOATS__
  try snapshot.gui.font.family.set(request.object.get("family").?.string);
  try snapshot.gui.font.style.set(request.object.get("style").?.string);
  snapshot.gui.font.thicken=request.object.get("thicken").?.bool;
  snapshot.gui.font.thicken_strength=@intCast(try number(request,"strength"));
  snapshot.gui.cursor.style=@enumFromInt(try number(request,"cursor"));
  snapshot.gui.cursor.blink=request.object.get("blink").?.bool;
  snapshot.gui.cursor.blink_interval_ms=@intCast(try number(request,"blink_ms"));
  snapshot.gui.window.background_blur=@intCast(try number(request,"blur"));
  const titlebar=try number(request,"titlebar");
  snapshot.gui.window.titlebar=if (titlebar==0) request.object.get("native_titlebar").?.bool else titlebar==2;
  const tag:std.meta.Tag(Key.Code)=@enumFromInt(try number(request,"code"));
  switch (tag) {
    .char=>snapshot.prefix.code=.{.char=.init(request.object.get("text").?.string)},
    inline else=>|name| snapshot.prefix.code=@unionInit(Key.Code,@tagName(name),{}),
  }
  const modifiers=try number(request,"modifiers");
  snapshot.prefix.mods=.{.ctrl=modifiers&1!=0,.alt=modifiers&2!=0,.shift=modifiers&4!=0,.super=modifiers&8!=0};
  snapshot.input_sequence_timeout_ns=try number(request,"timeout");
  snapshot.binding_count=@intCast(try number(request,"bindings"));
  var storage:[__CAPACITY__]u8=undefined;
  var writer:std.Io.Writer=.fixed(storage[0..try number(request,"capacity")]);
  const result=if (try number(request,"section")==0) originalGui(&snapshot,&writer) else originalInput(&snapshot,&writer);
  if (result) |_| {
    for (writer.buffered()) |byte| { _=putchar(byte); }
  } else |err| {
    if (err!=error.WriteFailed) { return err; }
    for ("\"WriteFailed\"") |byte| { _=putchar(byte); }
  }
  _=putchar('\n');
}
pub fn main() !void {
  var source:[65536]u8=undefined;
  var length:usize=0;
  while (true) {
    const byte=getchar();
    if (byte<0) { break; }
    if (byte=='\n') { try run(source[0..length]);length=0; } else {
      if (length==source.len) { return error.OracleInputTooLong; }
      source[length]=@intCast(byte);length+=1;
    }
  }
  if (length!=0) { return error.IncompleteOracleInput; }
}
"""


def gui_body(source):
    start = source.index(".gui => {") + len(".gui => {")
    depth = 1
    for end in range(start, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end]
    raise RuntimeError("The original GUI query has unbalanced braces")


def bits(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


def records():
    generator = random.Random(0x475549)
    default = dict(
        section=0,
        capacity=4096,
        family="",
        style="",
        thicken=False,
        strength=255,
        cursor=0,
        blink=True,
        blink_ms=600,
        blur=0,
        titlebar=0,
        native_titlebar=False,
        code=0,
        text="b",
        modifiers=1,
        timeout=1000000000,
        bindings=0,
        size=bits(15),
        line_height=bits(1),
        letter_spacing=bits(0),
        opacity=bits(1),
        padding_x=bits(0),
        padding_y=bits(0),
        chrome_scale=bits(1),
        sidebar_width=bits(284),
    )
    yield default
    for code in range(15):
        for modifiers in range(16):
            for text in ("b", "\x00", "é", "中", "🌱", "\x7f") if code == 0 else ("",):
                yield {
                    **default,
                    "section": 1,
                    "code": code,
                    "modifiers": modifiers,
                    "text": text,
                }
    for bindings in (0, 1, 255, 256):
        for timeout in (10000000, 1000000000, 10000000000, 2**64 - 1):
            yield {**default, "section": 1, "bindings": bindings, "timeout": timeout}
    for index in range(4096):
        value = {
            **default,
            "family": generator.choice(
                ("", "Iosevka Term", 'Font "中\\', "\x01" * 256)
            ),
            "style": generator.choice(("", "SemiBold", "Italic", "\n" * 256)),
            "thicken": bool(index & 1),
            "strength": generator.randrange(256),
            "cursor": index % 4,
            "blink": bool(index & 2),
            "blink_ms": generator.randrange(100, 5001),
            "blur": generator.randrange(256),
            "titlebar": index % 3,
            "native_titlebar": bool(index & 4),
        }
        bounds = {
            "size": (6, 96),
            "line_height": (0.75, 3),
            "letter_spacing": (-5, 20),
            "opacity": (0, 1),
            "padding_x": (0, 256),
            "padding_y": (0, 256),
            "chrome_scale": (0.5, 2),
            "sidebar_width": (220, 800),
        }
        for name, (low, high) in bounds.items():
            value[name] = bits(generator.uniform(low, high))
        if index % 5 == 0:
            value["opacity"] = generator.randrange(0, 0x3F800001)
            value["padding_x"] = bits(math.ldexp(1.0, -generator.randrange(1, 150)))
            value["letter_spacing"] = bits(-0.0)
        if index % 7 == 0:
            value["capacity"] = generator.randrange(4097)
        yield value


def compare(cases, binary, reference):
    payload = "".join(
        json.dumps(case, ensure_ascii=True, separators=(",", ":")) + "\n"
        for case in cases
    ).encode()
    original = subprocess.run(
        [str(reference)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    candidate = subprocess.run(
        [str(binary)], input=payload, capture_output=True, check=True
    ).stdout.splitlines()
    if len(original) != len(cases) or len(candidate) != len(cases):
        raise RuntimeError("Preferences query response count differs")
    for index, (left, right) in enumerate(zip(original, candidate)):
        if left != right:
            raise RuntimeError(
                f"Preferences query mismatch at {index}: request={cases[index]!r}, Zig={left!r}, C++={right!r}"
            )
    return original


def main():
    parser = argparse.ArgumentParser(
        description="Compare GUI and input configuration JSON with the extracted original Zig serializers"
    )
    parser.add_argument("--compiler", default="clang++")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    source = (root / "src/client/config/config_queries.zig").read_text()
    input_body = source.split(".input => ", 1)[1].split(",\n        .binding =>", 1)[0]
    if "snapshot.prefix" not in input_body or "gui.font.family.name()" not in gui_body(
        source
    ):
        raise RuntimeError("The original preferences query extraction contract changed")
    command = (root / "src/core/schema/messages/ClientCommand.zig").read_text()
    capacity = re.search(r"pub const capacity = ([0-9]+);", command).group(1)
    cpp = cpp_probe.replace(
        "__LOAD_FLOATS__",
        "\n".join(
            f'configuration.{path}=std::bit_cast<float>(static_cast<std::uint32_t>(number(request,"{name}")));'
            for name, path in float_fields.items()
        ),
    )
    zig = (
        zig_probe.replace("__GUI_BODY__", gui_body(source))
        .replace("__INPUT_BODY__", input_body)
        .replace("__CAPACITY__", capacity)
    )
    zig = zig.replace(
        "__LOAD_FLOATS__",
        "\n".join(
            f'snapshot.gui.{path}=@bitCast(@as(u32,@intCast(try number(request,"{name}"))));'
            for name, path in zig_float_fields.items()
        ),
    )
    cases = list(records())
    with tempfile.TemporaryDirectory(prefix="telar-preferences-query-") as directory:
        work = Path(directory)
        (work / "probe.cpp").write_text(cpp)
        (work / "probe.zig").write_text(zig)
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
                str(root / "services/runtime-cpp"),
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
                "gui_config",
                "--dep",
                "key",
                f"-Mroot={work / 'probe.zig'}",
                f"-Mgui_config={root / 'src/client/config/GuiConfig.zig'}",
                f"-Mkey={root / 'lib/keyinput/Key.zig'}",
                f"-femit-bin={work / 'zig'}",
            ],
            check=True,
        )
        original = compare(cases, work / "cpp", work / "zig")
        edges = []
        for case, response in list(zip(cases, original))[::17]:
            if json.loads(response) == "WriteFailed":
                continue
            for size in (0, len(response) - 1, len(response), len(response) + 1):
                edges.append({**case, "capacity": size})
        bounded = compare(edges, work / "cpp", work / "zig")
    failures = sum(json.loads(value) == "WriteFailed" for value in original + bounded)
    print(
        f"Matched {len(cases) + len(edges):,} GUI/input query records byte-for-byte, including {failures:,} bounded failures"
    )


if __name__ == "__main__":
    main()
