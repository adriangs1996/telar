import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import struct
import subprocess
import tempfile


zig_probe = r'''
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const status = @import("status");
const age = @import("age");
const Card = @import("card");
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

fn writeBytes(bytes: []const u8) !void {
    for (bytes) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}

fn writeText(text: []const u8) !void {
    const length: u32 = @intCast(text.len);
    try writeBytes(std.mem.asBytes(&length));
    try writeBytes(text);
}

fn statusRecord() !void {
    var request: [5]u32 = undefined;
    for (&request) |*value| value.* = try readUnsigned(u32);
    const state: core.AgentStatus = @enumFromInt(request[0]);
    const reason: core.AgentBlockedReason = @enumFromInt(request[1]);
    const connected = request[4] != 0;
    try writeText(status.label(state, reason));
    try writeText(status.glyph(state, reason));
    const effective = if (connected) state else .unknown;
    const word = if (connected) status.label(state, reason) else "offline";
    var buffer: [age.max_bytes]u8 = undefined;
    var text_buffer: [32]u8 = undefined;
    const text = switch (effective) {
        .working => try std.fmt.bufPrint(&text_buffer, "{s} {s}", .{word, age.duration(request[2], &buffer)}),
        .ready => age.format(request[2], &buffer),
        else => word,
    };
    try writeText(text);
    try writeText(age.format(request[2], &buffer));
    try writeText(age.duration(request[2], &buffer));
    try writeText(status.color(data.Palette{}, state));
    const alpha = status.pulse(@intCast(request[3]));
    try writeBytes(std.mem.asBytes(&alpha));
}

fn geometryRecord() !void {
    var request: [7]f32 = undefined;
    for (&request) |*value| value.* = @bitCast(try readUnsigned(u32));
    const card: Card = .{.small_row=request[0], .title_row=request[1], .glyph_width=0, .scale=request[2]};
    const dimensions = [_]f32{card.height(), card.pitch(), card.px(Card.padding_x), card.px(Card.padding_y)};
    try writeBytes(std.mem.asBytes(&dimensions));
    for (0..3) |index| {
        const row = card.row(.{.x=request[3], .y=request[4], .width=request[5], .height=request[6]}, @intCast(index));
        const values = [_]f32{row.x, row.y, row.width, row.height};
        try writeBytes(std.mem.asBytes(&values));
    }
}

pub fn main() !void {
    while (true) {
        const kind = getchar();
        if (kind < 0) return;
        switch (kind) {
            0 => try statusRecord(),
            1 => try geometryRecord(),
            else => return error.UnknownRequest,
        }
    }
}
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def enum_source(source, name):
    match = re.search(rf"pub const {name} = enum\(u8\) \{{.*?\n\}};", source, re.S)
    if not match:
        raise RuntimeError(f"Original {name} declaration was not found")

    return match.group()


def records():
    ages = [
        0, 1, 58, 59, 60, 61, 119, 120, 3599, 3600, 3601,
        86399, 86400, 86401, 9999 * 86400, 10000 * 86400, 2**32 - 1,
    ]
    statuses = itertools.product(range(6), range(5), ages, range(17), range(2))
    for state, reason, seconds, frame, connected in statuses:
        yield struct.pack("<B5I", 0, state, reason, seconds, frame, connected)

    for frame in range(256):
        yield struct.pack("<B5I", 0, 1, 0, 59, frame, 1)

    generator = random.Random(81247)
    scales = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4, 8]
    small_rows = [0, 8, 15, 21, 64]
    title_rows = [0, 10, 17, 28, 128]
    widths = [0, 1, 19, 20, 24, 257, 4096]
    for scale, small, title, width in itertools.product(scales, small_rows, title_rows, widths):
        yield struct.pack("<B7f", 1, small, title, scale, 8, 154, width, 69)

    for _ in range(30000):
        values = [
            generator.uniform(0, 4096),
            generator.uniform(0, 4096),
            generator.choice(scales),
            generator.uniform(-1000, 4000),
            generator.uniform(-1000, 4000),
            generator.uniform(-100, 8192),
            generator.uniform(0, 8192),
        ]
        yield struct.pack("<B7f", 1, *values)


def record_end(output, offset, kind):
    if kind == 1:
        return offset + 16 * 4

    for _ in range(6):
        length = struct.unpack_from("<I", output, offset)[0]
        offset += 4 + length

    return offset + 4


def compare(actual, expected, cases):
    actual_offset = expected_offset = 0
    for index, case in enumerate(cases):
        actual_end = record_end(actual, actual_offset, case[0])
        expected_end = record_end(expected, expected_offset, case[0])
        left = actual[actual_offset:actual_end]
        right = expected[expected_offset:expected_end]
        if left != right:
            raise RuntimeError(
                f"Agent presentation differs at record {index}: "
                f"input={case.hex()}, C++={left.hex()}, Zig={right.hex()}"
            )

        actual_offset, expected_offset = actual_end, expected_end

    if actual_offset != len(actual) or expected_offset != len(expected):
        raise RuntimeError("Unexpected trailing output")


def prepare_reference(root, work):
    types = (root / "src/core/schema/types.zig").read_text()
    declarations = [enum_source(types, name) for name in ["AgentStatus", "AgentBlockedReason"]]
    (work / "core.zig").write_text("\n".join(declarations))
    (work / "cellgrid.zig").write_text("pub const Color = []const u8;\n")

    roles = ["teal", "green", "yellow", "red", "overlay1"]
    palette = "".join(f'    {name}: []const u8 = "{name}",\n' for name in roles)
    (work / "model.zig").write_text("pub const Palette = struct {\n" + palette + "};\n")
    (work / "client.zig").write_text("pub const FleetCard = enum {agent, task_full, task_compact};\n")
    (work / "metrics.zig").write_text("cell_width: u32 = 0,\n")
    (work / "probe.zig").write_text(zig_probe)

    source = root / "src/gui/widgets"
    card = (source / "CardGeometry.zig").read_text()
    imports = {
        "../TerminalMetrics.zig": "metrics",
        "../image/SpriteSize.zig": "sprite-size",
        "ChromeMetrics.zig": "chrome-metrics",
    }
    for original, replacement in imports.items():
        card = card.replace(f'@import("{original}")', f'@import("{replacement}")')

    (work / "CardGeometry.zig").write_text(card)


def reference_command(root, work):
    source = root / "src/gui/widgets"

    return [
        "zig", "build-exe", "-O", "ReleaseSafe", "-lc",
        "--dep", "telar-core",
        "--dep", "model",
        "--dep", "status",
        "--dep", "age",
        "--dep", "card",
        f"-Mroot={work / 'probe.zig'}",
        f"-Mtelar-core={work / 'core.zig'}",
        f"-Mmodel={work / 'model.zig'}",
        f"-Mcellgrid={work / 'cellgrid.zig'}",
        "--dep", "cellgrid",
        "--dep", "model",
        "--dep", "telar-core",
        f"-Mstatus={source / 'status_glyph.zig'}",
        f"-Mage={source / 'age_label.zig'}",
        "--dep", "gfx",
        "--dep", "telar-client",
        "--dep", "metrics",
        "--dep", "sprite-size",
        "--dep", "chrome-metrics",
        f"-Mcard={work / 'CardGeometry.zig'}",
        f"-Mgfx={root / 'lib/gfx/root.zig'}",
        f"-Mtelar-client={work / 'client.zig'}",
        f"-Mmetrics={work / 'metrics.zig'}",
        f"-Msprite-size={source.parent / 'image/SpriteSize.zig'}",
        "--dep", "telar-client",
        f"-Mchrome-metrics={source / 'ChromeMetrics.zig'}",
        f"-femit-bin={work / 'zig'}",
    ]


def validation_report(root, cpp, work, cases, command):
    paths = [
        "src/core/schema/types.zig",
        "src/gui/widgets/status_glyph.zig",
        "src/gui/widgets/age_label.zig",
        "src/gui/widgets/CardGeometry.zig",
        "services/gui-cpp/presentation/agent_status.hpp",
        "services/gui-cpp/presentation/agent_card_geometry.hpp",
        "services/gui-cpp/tools/agent_presentation_probe.cpp",
        "services/gui-cpp/tools/check_agent_presentation.py",
    ]

    return {
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": (
            "Original status words, glyphs, named palette roles, formatted ages, "
            "pulse frames and three-row card geometry. "
            "Does not prove full fleet order or rendered pixels."
        ),
        "reference_adaptation": (
            "Palette colors are represented by their role names. "
            "CardGeometry imports are redirected to isolated type facades; "
            "its original function bodies are retained. "
            "The geometry corpus supplies row heights directly."
        ),
        "cases": len(cases),
        "status_cases": sum(case[0] == 0 for case in cases),
        "geometry_cases": sum(case[0] == 1 for case in cases),
        "input_sha256": sha(work / "input.bin"),
        "output_sha256": sha(work / "cpp.bin"),
        "cpp_binary_sha256": sha(cpp),
        "zig_binary_sha256": sha(work / "zig"),
        "source_sha256": {p: sha(root / p) for p in paths},
        "generated_reference_sha256": {p.name: sha(p) for p in sorted(work.glob("*.zig"))},
        "zig_command": command,
    }


def run(root, build, work):
    work.mkdir(parents=True, exist_ok=True)
    prepare_reference(root, work)
    command = reference_command(root, work)
    subprocess.run(command, check=True)

    cases = list(records())
    payload = b"".join(cases)
    cpp = build / "gui-agent-presentation-probe"
    expected = subprocess.run(
        [str(work / "zig")], input=payload, capture_output=True, check=True
    ).stdout
    actual = subprocess.run(
        [str(cpp)], input=payload, capture_output=True, check=True
    ).stdout
    (work / "input.bin").write_bytes(payload)
    (work / "zig.bin").write_bytes(expected)
    (work / "cpp.bin").write_bytes(actual)
    compare(actual, expected, cases)

    report = validation_report(root, cpp, work, cases, command)
    (work / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(
        description="Compare agent presentation with the original Zig functions"
    )
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--output-dir", type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    build = (options.build_dir or root / "services/gui-cpp/out").resolve()
    if options.output_dir:
        run(root, build, options.output_dir.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="telar-agent-presentation-") as directory:
            run(root, build, Path(directory))


if __name__ == "__main__":
    main()
