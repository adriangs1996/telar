const OscScanner = @import("OscScanner.zig");
const osc_ops = @import("osc.zig");
const std = @import("std");
const Observation = @import("Observation.zig");
const builtin = @import("builtin");
const Clock = @import("Clock.zig");
const OscCompletion = @import("OscCompletion.zig");
const Tracker = @This();

scanner: OscScanner = .{},
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
pub fn feed(self: *Tracker, observation: Observation, sink: anytype) void {
    for (observation.bytes) |byte| switch (self.scanner.next(byte)) {
        .none => {},
        .start => {
            if (comptime builtin.mode == .Debug) {
                self.osc_started += 1;
            }
            self.osc_len = 0;
            self.osc_overflow = false;
        },
        .byte => |value| self.appendOsc(value),
        .end => self.finishOsc(observation.clock, sink),
    };
}

/// Records bytes traveling from the client to the PTY while the shell has
/// declared an editable command zone. Output is deliberately excluded:
/// asynchronous prompts and notifications may draw between B and C.
///
/// ```zig
/// const captured = tracker.input(bytes);
/// ```
pub fn input(self: *Tracker, bytes: []const u8) usize {
    const before = self.command_len;
    for (bytes) |byte| self.captureByte(byte);
    return self.command_len - before;
}

/// Emits the running command as interrupted, if one exists.
///
/// ```zig
/// tracker.interrupt(clock, &sink);
/// ```
pub fn interrupt(self: *Tracker, clock: Clock, sink: anytype) void {
    if (!self.running) {
        return;
    }
    self.emit(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
}

pub fn currentCwd(self: *const Tracker) []const u8 {
    return self.cwd[0..self.cwd_len];
}

pub fn updateCwd(self: *Tracker, cwd: []const u8) void {
    self.setCwd(cwd);
}

fn captureByte(self: *Tracker, byte: u8) void {
    if (self.zone != .input) {
        return;
    }
    if (self.command_len == self.command.len) {
        self.command_truncated = true;
        return;
    }
    self.command[self.command_len] = byte;
    self.command_len += 1;
}

fn appendOsc(self: *Tracker, byte: u8) void {
    if (self.osc_len == self.osc.len) {
        self.osc_overflow = true;
        return;
    }
    self.osc[self.osc_len] = byte;
    self.osc_len += 1;
}

fn finishOsc(self: *Tracker, clock: Clock, sink: anytype) void {
    if (comptime builtin.mode == .Debug) {
        self.osc_finished += 1;
    }
    defer {
        self.osc_len = 0;
        self.osc_overflow = false;
    }
    if (self.osc_overflow) {
        return;
    }
    const payload = self.osc[0..self.osc_len];
    const separator = std.mem.indexOfScalar(u8, payload, ';') orelse payload.len;
    const code = payload[0..separator];
    const body = if (separator == payload.len) "" else payload[separator + 1 ..];
    if (std.mem.eql(u8, code, "133")) {
        self.semantic(.{ .body = body, .clock = clock }, sink);
    } else if (std.mem.eql(u8, code, "7")) {
        self.cwdReport(body);
    }
}

fn semantic(self: *Tracker, observation: SemanticObservation, sink: anytype) void {
    const body = observation.body;
    const clock = observation.clock;

    const separator = std.mem.indexOfScalar(u8, body, ';') orelse body.len;
    const action = body[0..separator];
    const options = if (separator == body.len) "" else body[separator + 1 ..];
    if (std.mem.eql(u8, action, "A") or std.mem.eql(u8, action, "P")) {
        if (comptime builtin.mode == .Debug) {
            self.prompt_markers += 1;
        }
        if (self.running) {
            self.emit(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
        }
        self.zone = .prompt;
        self.resetCommand();
    } else if (std.mem.eql(u8, action, "B")) {
        if (comptime builtin.mode == .Debug) {
            self.input_markers += 1;
        }
        self.zone = .input;
        self.resetCommand();
    } else if (std.mem.eql(u8, action, "C")) {
        if (comptime builtin.mode == .Debug) {
            self.output_markers += 1;
        }
        self.zone = .output;
        self.running = self.command_len != 0;
        self.started_at_ms = clock.real_ms;
        self.started_awake_ns = clock.awake_ns;
    } else if (std.mem.eql(u8, action, "D")) {
        if (comptime builtin.mode == .Debug) {
            self.finished_markers += 1;
        }
        self.zone = .prompt;
        if (self.running) {
            self.emit(.{ .clock = clock, .exit_code = osc_ops.parseExitCode(options), .status = .completed }, sink);
        }
    }
}

fn emit(self: *Tracker, completion: OscCompletion, sink: anytype) void {
    const duration = @max(@as(i64, 0), completion.clock.awake_ns - self.started_awake_ns);
    sink.emit(.{
        .bytes = self.command[0..self.command_len],
        .cwd = self.currentCwd(),
        .started_at_ms = self.started_at_ms,
        .duration_ns = duration,
        .exit_code = completion.exit_code,
        .status = completion.status,
        .truncated = self.command_truncated,
    });
    self.running = false;
    self.resetCommand();
}

fn resetCommand(self: *Tracker) void {
    self.command_len = 0;
    self.command_truncated = false;
}

fn cwdReport(self: *Tracker, body: []const u8) void {
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
    self.cwd_len = osc_ops.percentDecode(encoded, &self.cwd) orelse return;
}

fn setCwd(self: *Tracker, cwd: []const u8) void {
    self.cwd_len = @min(cwd.len, self.cwd.len);
    @memcpy(self.cwd[0..self.cwd_len], cwd[0..self.cwd_len]);
}

const SemanticObservation = struct {
    body: []const u8,
    clock: Clock,
};
