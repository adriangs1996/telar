const OscScannerType = @import("OscScanner.zig");
const osc_ops = @import("osc.zig");
const std = @import("std");
const Observation = @import("Observation.zig");
const builtin = @import("builtin");
const Clock = @import("Clock.zig");
const SemanticObservation = @import("SemanticObservation.zig");
const OscCompletion = @import("OscCompletion.zig");
const Tracker = @This();

scanner: OscScannerType = .{},
zone: Zone = .unknown,
osc: [osc_ops.max_osc_bytes]u8 = undefined,
osc_len: usize = 0,
osc_overflow: bool = false,
command: [osc_ops.max_command_bytes]u8 = undefined,
command_len: usize = 0,
command_truncated: bool = false,
cwd: [std.fs.max_path_bytes]u8 = undefined,
cwd_len: usize = 0,
running: bool = false,
started_at_ms: i64 = 0,
started_awake_ns: i64 = 0,
prompt_markers: u64 = 0,
input_markers: u64 = 0,
output_markers: u64 = 0,
finished_markers: u64 = 0,
osc_started: u64 = 0,
osc_finished: u64 = 0,

const Zone = enum { unknown, prompt, input, output };

pub fn init(cwd: []const u8) Tracker {
    var tracker: Tracker = .{};
    tracker.setCwd(cwd);
    return tracker;
}

/// Consumes one output slice and emits completed OSC 133 commands to a
/// statically dispatched sink exposing `emit(Command)`.
///
/// ```zig
/// tracker.feed(.{ .bytes = output, .clock = clock }, &sink);
/// ```
pub fn feed(tracker: *Tracker, observation: Observation, sink: anytype) void {
    for (observation.bytes) |byte| switch (tracker.scanner.next(byte)) {
        .none => {},
        .start => {
            if (comptime builtin.mode == .Debug) {
                tracker.osc_started += 1;
            }
            tracker.osc_len = 0;
            tracker.osc_overflow = false;
        },
        .byte => |value| tracker.appendOsc(value),
        .end => tracker.finishOsc(observation.clock, sink),
    };
}

/// Records bytes traveling from the client to the PTY while the shell has
/// declared an editable command zone. Output is deliberately excluded:
/// asynchronous prompts and notifications may draw between B and C.
///
/// ```zig
/// const captured = tracker.input(bytes);
/// ```
pub fn input(tracker: *Tracker, bytes: []const u8) usize {
    const before = tracker.command_len;
    for (bytes) |byte| tracker.captureByte(byte);
    return tracker.command_len - before;
}

/// Emits the running command as interrupted, if one exists.
///
/// ```zig
/// tracker.interrupt(clock, &sink);
/// ```
pub fn interrupt(tracker: *Tracker, clock: Clock, sink: anytype) void {
    if (!tracker.running) {
        return;
    }
    tracker.emit(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
}

pub fn currentCwd(tracker: *const Tracker) []const u8 {
    return tracker.cwd[0..tracker.cwd_len];
}

pub fn updateCwd(tracker: *Tracker, cwd: []const u8) void {
    tracker.setCwd(cwd);
}

fn captureByte(tracker: *Tracker, byte: u8) void {
    if (tracker.zone != .input) {
        return;
    }
    if (tracker.command_len == tracker.command.len) {
        tracker.command_truncated = true;
        return;
    }
    tracker.command[tracker.command_len] = byte;
    tracker.command_len += 1;
}

fn appendOsc(tracker: *Tracker, byte: u8) void {
    if (tracker.osc_len == tracker.osc.len) {
        tracker.osc_overflow = true;
        return;
    }
    tracker.osc[tracker.osc_len] = byte;
    tracker.osc_len += 1;
}

fn finishOsc(tracker: *Tracker, clock: Clock, sink: anytype) void {
    if (comptime builtin.mode == .Debug) {
        tracker.osc_finished += 1;
    }
    defer {
        tracker.osc_len = 0;
        tracker.osc_overflow = false;
    }
    if (tracker.osc_overflow) {
        return;
    }
    const payload = tracker.osc[0..tracker.osc_len];
    const separator = std.mem.indexOfScalar(u8, payload, ';') orelse payload.len;
    const code = payload[0..separator];
    const body = if (separator == payload.len) "" else payload[separator + 1 ..];
    if (std.mem.eql(u8, code, "133")) {
        tracker.semantic(.{ .body = body, .clock = clock }, sink);
    } else if (std.mem.eql(u8, code, "7")) {
        tracker.cwdReport(body);
    }
}

fn semantic(tracker: *Tracker, observation: SemanticObservation, sink: anytype) void {
    const body = observation.body;
    const clock = observation.clock;

    const separator = std.mem.indexOfScalar(u8, body, ';') orelse body.len;
    const action = body[0..separator];
    const options = if (separator == body.len) "" else body[separator + 1 ..];
    if (std.mem.eql(u8, action, "A") or std.mem.eql(u8, action, "P")) {
        if (comptime builtin.mode == .Debug) {
            tracker.prompt_markers += 1;
        }
        if (tracker.running) {
            tracker.emit(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
        }
        tracker.zone = .prompt;
        tracker.resetCommand();
    } else if (std.mem.eql(u8, action, "B")) {
        if (comptime builtin.mode == .Debug) {
            tracker.input_markers += 1;
        }
        tracker.zone = .input;
        tracker.resetCommand();
    } else if (std.mem.eql(u8, action, "C")) {
        if (comptime builtin.mode == .Debug) {
            tracker.output_markers += 1;
        }
        tracker.zone = .output;
        tracker.running = tracker.command_len != 0;
        tracker.started_at_ms = clock.real_ms;
        tracker.started_awake_ns = clock.awake_ns;
    } else if (std.mem.eql(u8, action, "D")) {
        if (comptime builtin.mode == .Debug) {
            tracker.finished_markers += 1;
        }
        tracker.zone = .prompt;
        if (tracker.running) {
            tracker.emit(.{ .clock = clock, .exit_code = osc_ops.parseExitCode(options), .status = .completed }, sink);
        }
    }
}

fn emit(tracker: *Tracker, completion: OscCompletion, sink: anytype) void {
    const duration = @max(@as(i64, 0), completion.clock.awake_ns - tracker.started_awake_ns);
    sink.emit(.{
        .bytes = tracker.command[0..tracker.command_len],
        .cwd = tracker.currentCwd(),
        .started_at_ms = tracker.started_at_ms,
        .duration_ns = duration,
        .exit_code = completion.exit_code,
        .status = completion.status,
        .truncated = tracker.command_truncated,
    });
    tracker.running = false;
    tracker.resetCommand();
}

fn resetCommand(tracker: *Tracker) void {
    tracker.command_len = 0;
    tracker.command_truncated = false;
}

fn cwdReport(tracker: *Tracker, body: []const u8) void {
    const prefixes = [_][]const u8{ "file://", "kitty-shell-cwd://" };
    var path: ?[]const u8 = null;
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, body, prefix)) {
            continue;
        }
        const authority_and_path = body[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return;
        path = authority_and_path[slash..];
        break;
    }
    const encoded = path orelse return;
    tracker.cwd_len = osc_ops.percentDecode(encoded, &tracker.cwd) orelse return;
}

fn setCwd(tracker: *Tracker, cwd: []const u8) void {
    tracker.cwd_len = @min(cwd.len, tracker.cwd.len);
    @memcpy(tracker.cwd[0..tracker.cwd_len], cwd[0..tracker.cwd_len]);
}
