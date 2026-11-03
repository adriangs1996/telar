import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_activity_order import declaration


reference = r'''
const std = @import("std");
const core = @import("telar-core");
const Playback = @import("model/agents/SoundPlayback.zig");
const Outcome = @import("model/agents/SoundRequestOutcome.zig").SoundRequestOutcome;
const Policy = @import("model/config/SoundPolicy.zig");
const Payload = @import("model/notifications/NotificationPayload.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) return error.TruncatedInput;
        byte.* = @intCast(value);
    }
    return @bitCast(bytes);
}
fn write(value: anytype) !void {
    for (std.mem.asBytes(&value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn readPolicy() !Policy {
    const enabled = try read(u8);
    const ready = try read(u8);
    const needs_input = try read(u8);
    return .{ .enabled = enabled != 0, .ready = ready != 0, .needs_input = needs_input != 0 };
}
fn readText(allocator: std.mem.Allocator) ![]const u8 {
    const text = try allocator.alloc(u8, try read(u16));
    for (text) |*byte| byte.* = try read(u8);
    return text;
}
fn writeText(text: []const u8) !void {
    try write(@as(u16, @intCast(text.len)));
    for (text) |byte| try write(byte);
}
fn operate(playback: *Playback, operation: u8, allocator: std.mem.Allocator) !Outcome {
    switch (operation) {
        0 => playback.* = .init(try readPolicy()),
        1 => playback.configure(try readPolicy()),
        2 => return playback.request(@enumFromInt(try read(u8))),
        3 => if (playback.complete()) |sound| { return .{ .start = sound }; },
        4 => playback.schedulingFailed(),
        5 => {
            const title = try readText(allocator);
            const message = try readText(allocator);
            const payload: Payload = .init(title, message);
            try writeText(payload.titleSlice());
            try writeText(payload.messageSlice());
        },
        else => return error.InvalidOperation,
    }
    return .ignored;
}
fn writeSnapshot(playback: *const Playback, outcome: Outcome) !void {
    try write(@as(u8, @intFromEnum(std.meta.activeTag(outcome))));
    const sound: core.AgentSound = switch (outcome) { .start => |kind| kind, else => .ready };
    try write(@as(u8, @intFromEnum(sound)));
    const snapshot = playback.snapshot();
    try write(@as(u8, @intFromBool(snapshot.active)));
    try write(@as(u8, @intFromBool(snapshot.queued != null)));
    try write(@as(u8, @intFromEnum(snapshot.queued orelse .ready)));
    try write(@as(u8, @intFromBool(snapshot.configuration.enabled)));
    try write(@as(u8, @intFromBool(snapshot.configuration.ready)));
    try write(@as(u8, @intFromBool(snapshot.configuration.needs_input)));
}
pub fn main() !void {
    var playback: Playback = .init(.{});
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const outcome = try operate(&playback, @intCast(operation), arena.allocator());
        try writeSnapshot(&playback, outcome);
    }
}
'''


def text(value):
    data = value.encode() if isinstance(value, str) else value
    return struct.pack("<H", len(data)) + data


def fixtures():
    cases = []
    policies = list(itertools.product((False, True), repeat=3))
    for policy in policies:
        for sound in (0, 1):
            cases.append(bytes((0, *policy)))
            cases.append(bytes((2, sound)))
            if policy[0] and policy[sound + 1]:
                cases.append(bytes((3,)))

    for first, second, third, policy in itertools.product((0, 1), (0, 1), (0, 1), policies):
        cases.extend((bytes((0, 1, 1, 1)), bytes((2, first)), bytes((2, second)), bytes((1, *policy)), bytes((2, third)), bytes((3,))))

    for sound in (0, 1):
        cases.extend((bytes((0, 1, 1, 1)), bytes((2, sound)), bytes((4,)), bytes((2, sound)), bytes((3,))))

    generator = random.Random(0x736F756E64)
    for _ in range(64):
        cases.extend((bytes((0, 1, 1, 1)), bytes((2, generator.randrange(2)))))
        for _ in range(128):
            if generator.randrange(4) == 0:
                cases.append(bytes((1, *generator.choice(policies))))
            else:
                cases.append(bytes((2, generator.randrange(2))))
        cases.append(bytes((3,)))

    labels = [
        "", "Agent needs input", 'A "quoted" title\\', "line\nnext\tend\x7f",
        "é" * 300, "中" * 200, "👩🏽‍💻" * 100,
        b"\xff\xc0\x80\x00\x1b\x7f\x80", bytes(range(256)) * 4,
    ]
    for boundary in (96, 512):
        for offset in range(-4, 5):
            for suffix in ("é", "中", "🌱", '\\"\n'):
                labels.append("a" * (boundary + offset) + suffix)
    for label in labels:
        cases.append(bytes((5,)) + text(label) + text(label))
    for _ in range(2048):
        title = bytes(generator.randrange(256) for _ in range(generator.randrange(0, 700)))
        message = bytes(generator.randrange(256) for _ in range(generator.randrange(0, 1500)))
        cases.append(bytes((5,)) + text(title) + text(message))
    return cases


def prepare(root, work):
    sources = [f"src/model/agents/{name}" for name in ("SoundPlayback.zig", "SoundRequestOutcome.zig", "SoundSnapshot.zig", "sound_playback.zig")]
    sources += ["src/model/config/SoundPolicy.zig", "src/model/notifications/NotificationPayload.zig"]
    for name in sources:
        destination = work / name.removeprefix("src/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
    types = (root / "src/core/schema/types.zig").read_text()
    (work / "core.zig").write_text("\n".join(declaration(types, name) for name in ("AgentSound", "max_notification_title_bytes", "max_notification_message_bytes")))
    (work / "probe.zig").write_text(reference)
    command = ["zig", "build-exe", "-O", "ReleaseSafe", "-lc", "--dep", "telar-core", f"-Mroot={work / 'probe.zig'}", f"-Mtelar-core={work / 'core.zig'}", f"-femit-bin={work / 'original'}"]
    with (work / "reference-build.log").open("w") as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True, timeout=180)
    return sources + ["src/core/schema/types.zig"], command


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, default=root / "services/gui-cpp/out")
    parser.add_argument("--output-dir", type=Path, required=True)
    options = parser.parse_args()
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    sources, command = prepare(root, work)
    cases = fixtures()
    payload = b"".join(cases)
    (work / "input.bin").write_bytes(payload)
    outputs = []
    binary = options.build_dir.resolve() / "gui-notification-effects-probe"
    for name, executable in (("original", work / "original"), ("cpp", binary)):
        result = subprocess.run([executable], input=payload, capture_output=True, check=True, timeout=120)
        (work / (name + ".bin")).write_bytes(result.stdout)
        outputs.append(result.stdout)
    if outputs[0] != outputs[1]:
        offset = next((index for index, pair in enumerate(zip(*outputs)) if pair[0] != pair[1]), min(map(len, outputs)))
        raise RuntimeError(f"Notification effect mismatch at byte {offset}; retained input and both outputs")
    sources += ["services/gui-cpp/application/sound_playback.hpp", "services/gui-cpp/application/notification_payload.hpp", "services/gui-cpp/tools/notification_effects_probe.cpp", "services/gui-cpp/tools/check_notification_effects.py"]
    sources += [
        "services/gui-cpp/tools/check_activity_order.py",
        "services/gui-cpp/text/bounded_text.hpp",
        "services/gui-cpp/core/configuration.hpp",
        "dlls/telar-base/include/telar_base/memory/fixed_text.hpp",
        "dlls/telar-client/include/telar_client/serializers/telar_protocol.hpp",
    ]
    result = {
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "Original sound playback/policy/coalescing state and host payload byte sanitization; no real sound or operating-system notification delivery",
        "operations": len(cases),
        "input_sha256": hashlib.sha256(payload).hexdigest(),
        "output_sha256": hashlib.sha256(outputs[0]).hexdigest(),
        "output_bytes": len(outputs[0]),
        "source_sha256": {name: sha(root / name) for name in sources},
        "generated_sha256": {name: sha(work / name) for name in ("core.zig", "probe.zig")},
        "candidate_binary_sha256": sha(binary),
        "reference_command": command,
    }
    (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({name:result[name] for name in ("operations", "output_sha256", "output_bytes")}))


if __name__ == "__main__":
    main()
