import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import struct
import subprocess


zig_probe = r'''
const std = @import("std");
const metrics = @import("metrics");
const MetricName = @import("metric-name").MetricName;
const SystemMetrics = @import("system");
const CpuHistory = @import("history");
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

fn metric() !void {
    var request: [6]u32 = undefined;
    for (&request) |*value| value.* = try readUnsigned(u32);
    const name: MetricName = @enumFromInt(request[0]);
    const sample: ?SystemMetrics = if (request[1] == 0) null else .{
        .runtime_revision = 1,
        .cpu_percent = @intCast(request[2]),
        .memory_used_decigib = @intCast(request[3]),
        .battery_percent = if (request[4] == 0) null else @intCast(request[5]),
    };
    try writeText(if (metrics.available(name, sample)) "1" else "0");
    try writeText(if (metrics.icon(name)) |icon| icon.nerdGlyph() else "");
    var buffer: [metrics.max_value_bytes]u8 = undefined;
    try writeText(metrics.value(&buffer, name, sample));
    try writeText(@tagName(metrics.tone(name, sample).inkRole()));
}

fn history() !void {
    const count = try readUnsigned(u32);
    var samples: CpuHistory = .{};
    var buffer: [CpuHistory.capacity]u8 = undefined;
    for (0..count) |_| {
        samples.push(try readUnsigned(u8));
        try writeText(samples.ordered(&buffer));
    }
}

pub fn main() !void {
    while (true) {
        const kind = getchar();
        if (kind < 0) return;
        switch (kind) {
            0 => try metric(),
            1 => try history(),
            else => return error.UnknownRequest,
        }
    }
}
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def requests():
    for metric in range(3):
        yield b"\0" + struct.pack("<6I", metric, 0, 0, 0, 0, 0)

    for percent in range(101):
        yield b"\0" + struct.pack("<6I", 0, 1, percent, 0, 0, 0)

    for used_memory in range(65536):
        yield b"\0" + struct.pack("<6I", 1, 1, 0, used_memory, 0, 0)

    for present in [0, 1]:
        for percent in range(101):
            yield b"\0" + struct.pack("<6I", 2, 1, 0, 0, present, percent)

    rng = random.Random(0xBA412)
    for count in [0, 1, 9, 31, 32, 33, 64, 65, 127, 1024]:
        for pattern in [0, 100, None]:
            values = bytes(rng.randrange(101) if pattern is None else pattern for _ in range(count))
            yield b"\1" + struct.pack("<I", count) + values


def prepare_reference(root, work):
    original = root / "src/model"
    metric_source = (original / "bars/bar_metrics.zig").read_text()
    replacements = {
        "MetricName.zig": "metric-name",
        "../state/SystemMetrics.zig": "system",
        "Tone.zig": "tone",
        "../layout/icons.zig": "icons",
    }
    for name, module in replacements.items():
        metric_source = metric_source.replace(f'@import("{name}")', f'@import("{module}")')

    (work / "metrics.zig").write_text(metric_source)
    tone = (original / "bars/Tone.zig").read_text().replace('@import("model.zig")', '@import("palette")')
    (work / "tone.zig").write_text(tone)
    palette = re.search(r"pub const PaletteColor = enum \{.*?\n\};", (original / "bars/model.zig").read_text(), re.S)
    if palette is None:
        raise RuntimeError("Original PaletteColor definition was not found")

    (work / "palette.zig").write_text(palette.group() + "\n")
    (work / "core.zig").write_text("")
    (work / "probe.zig").write_text(zig_probe)

    return [
        "zig", "build-exe", "-O", "ReleaseSafe", "-lc",
        "--dep", "metrics", "--dep", "metric-name", "--dep", "system", "--dep", "history",
        f"-Mroot={work / 'probe.zig'}",
        "--dep", "metric-name", "--dep", "system", "--dep", "tone", "--dep", "icons",
        f"-Mmetrics={work / 'metrics.zig'}",
        f"-Mmetric-name={original / 'bars/MetricName.zig'}",
        f"-Msystem={original / 'state/SystemMetrics.zig'}",
        f"-Mhistory={original / 'state/CpuHistory.zig'}",
        "--dep", "palette", f"-Mtone={work / 'tone.zig'}",
        f"-Mpalette={work / 'palette.zig'}",
        "--dep", "telar-core", f"-Micons={original / 'layout/icons.zig'}",
        f"-Mtelar-core={work / 'core.zig'}",
        f"-femit-bin={work / 'zig'}",
    ]


def run(root, build, output):
    output.mkdir(parents=True, exist_ok=True)
    command = prepare_reference(root, output)
    subprocess.run(command, check=True)
    cases = list(requests())
    payload = b"".join(cases)
    (output / "input.bin").write_bytes(payload)
    cpp = build / "gui-bar-metrics-probe"
    results = {}
    for name, executable in [("zig", output / "zig"), ("cpp", cpp)]:
        result = subprocess.run([str(executable)], input=payload, capture_output=True, check=True)
        (output / f"{name}.bin").write_bytes(result.stdout)
        results[name] = result.stdout

    if results["zig"] != results["cpp"]:
        first = next((index for index, pair in enumerate(zip(results["zig"], results["cpp"])) if pair[0] != pair[1]), min(map(len, results.values())))
        raise RuntimeError(f"Bar metrics differ at output byte {first}; inspect {output}")

    paths = [
        "src/model/bars/bar_metrics.zig", "src/model/bars/MetricName.zig", "src/model/bars/Tone.zig",
        "src/model/bars/model.zig", "src/model/state/SystemMetrics.zig", "src/model/state/CpuHistory.zig", "src/model/layout/icons.zig",
        "services/gui-cpp/core/cpu_history.hpp", "services/gui-cpp/presentation/bar_metrics.hpp",
        "services/gui-cpp/tools/bar_metrics_probe.cpp", "services/gui-cpp/tools/check_bar_metrics.py",
    ]
    report = {
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "Metric availability, glyphs, text and named ink roles; fixed CPU ring output after every push. Rendering, layout, reconciliation and configuration are outside this oracle.",
        "reference_adaptation": "Original function bodies are retained. BarMetrics and Tone imports are redirected to the original types and isolated palette enum. Unused agent icon dependencies use an empty core facade.",
        "metric_records": sum(case[0] == 0 for case in cases),
        "history_requests": sum(case[0] == 1 for case in cases),
        "history_snapshots": sum(struct.unpack_from("<I", case, 1)[0] for case in cases if case[0] == 1),
        "input_sha256": sha(output / "input.bin"),
        "output_sha256": sha(output / "cpp.bin"),
        "cpp_binary_sha256": sha(cpp),
        "zig_binary_sha256": sha(output / "zig"),
        "source_sha256": {str(path): sha(root / path) for path in paths},
        "generated_reference_sha256": {path.name: sha(path) for path in sorted(output.glob("*.zig"))},
        "zig_command": command,
    }
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=Path("services/gui-cpp/out"))
    parser.add_argument("--output-dir", type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    run(root, options.build_dir.resolve(), options.output_dir.resolve())


if __name__ == "__main__":
    main()
