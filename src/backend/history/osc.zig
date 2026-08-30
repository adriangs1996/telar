//! OSC 133 command-zone tracker for one PTY.

const std = @import("std");
const builtin = @import("builtin");
const escape = @import("escape.zig");

pub const max_command_bytes = 64 * 1024;
const max_osc_bytes = 8 * 1024;

pub const Clock = struct {
    real_ms: i64,
    awake_ns: i64,
};

pub const Status = enum {
    completed,
    interrupted,
};

pub const Command = struct {
    bytes: []const u8,
    cwd: []const u8,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: Status,
    truncated: bool,
};

pub const Observation = struct {
    bytes: []const u8,
    clock: Clock,
};

const SemanticObservation = struct {
    body: []const u8,
    clock: Clock,
};

const Completion = struct {
    clock: Clock,
    exit_code: ?i32,
    status: Status,
};

pub const Tracker = struct {
    scanner: escape.OscScanner = .{},
    zone: Zone = .unknown,
    osc: [max_osc_bytes]u8 = undefined,
    osc_len: usize = 0,
    osc_overflow: bool = false,
    command: [max_command_bytes]u8 = undefined,
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
                if (comptime builtin.mode == .Debug) tracker.osc_started += 1;
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
        if (!tracker.running) return;
        tracker.emit(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
    }

    pub fn currentCwd(tracker: *const Tracker) []const u8 {
        return tracker.cwd[0..tracker.cwd_len];
    }

    pub fn updateCwd(tracker: *Tracker, cwd: []const u8) void {
        tracker.setCwd(cwd);
    }

    fn captureByte(tracker: *Tracker, byte: u8) void {
        if (tracker.zone != .input) return;
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
        if (comptime builtin.mode == .Debug) tracker.osc_finished += 1;
        defer {
            tracker.osc_len = 0;
            tracker.osc_overflow = false;
        }
        if (tracker.osc_overflow) return;
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
            if (comptime builtin.mode == .Debug) tracker.prompt_markers += 1;
            if (tracker.running)
                tracker.emit(.{ .clock = clock, .exit_code = null, .status = .interrupted }, sink);
            tracker.zone = .prompt;
            tracker.resetCommand();
        } else if (std.mem.eql(u8, action, "B")) {
            if (comptime builtin.mode == .Debug) tracker.input_markers += 1;
            tracker.zone = .input;
            tracker.resetCommand();
        } else if (std.mem.eql(u8, action, "C")) {
            if (comptime builtin.mode == .Debug) tracker.output_markers += 1;
            tracker.zone = .output;
            tracker.running = tracker.command_len != 0;
            tracker.started_at_ms = clock.real_ms;
            tracker.started_awake_ns = clock.awake_ns;
        } else if (std.mem.eql(u8, action, "D")) {
            if (comptime builtin.mode == .Debug) tracker.finished_markers += 1;
            tracker.zone = .prompt;
            if (tracker.running)
                tracker.emit(.{ .clock = clock, .exit_code = parseExitCode(options), .status = .completed }, sink);
        }
    }

    fn emit(tracker: *Tracker, completion: Completion, sink: anytype) void {
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
            if (!std.mem.startsWith(u8, body, prefix)) continue;
            const authority_and_path = body[prefix.len..];
            const slash = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return;
            path = authority_and_path[slash..];
            break;
        }
        const encoded = path orelse return;
        tracker.cwd_len = percentDecode(encoded, &tracker.cwd) orelse return;
    }

    fn setCwd(tracker: *Tracker, cwd: []const u8) void {
        tracker.cwd_len = @min(cwd.len, tracker.cwd.len);
        @memcpy(tracker.cwd[0..tracker.cwd_len], cwd[0..tracker.cwd_len]);
    }
};

fn parseExitCode(options: []const u8) ?i32 {
    const first = options[0 .. std.mem.indexOfScalar(u8, options, ';') orelse options.len];
    if (first.len == 0) return null;
    return std.fmt.parseInt(i32, first, 10) catch null;
}

fn percentDecode(input: []const u8, output: []u8) ?usize {
    var source: usize = 0;
    var destination: usize = 0;
    while (source < input.len) {
        if (destination == output.len) return null;
        if (input[source] == '%') {
            if (source + 2 >= input.len) return null;
            const high = std.fmt.charToDigit(input[source + 1], 16) catch return null;
            const low = std.fmt.charToDigit(input[source + 2], 16) catch return null;
            output[destination] = @intCast(high * 16 + low);
            source += 3;
        } else {
            output[destination] = input[source];
            source += 1;
        }
        destination += 1;
    }
    return destination;
}

const Collected = struct {
    count: usize = 0,
    last: ?Command = null,

    pub fn emit(self: *Collected, command: Command) void {
        self.count += 1;
        self.last = command;
    }
};

test "tracks command lifecycle across chunk boundaries" {
    var tracker = Tracker.init("/work");
    var collected: Collected = .{};
    tracker.feed(.{
        .bytes = "\x1b]133;A\x07$ \x1b]133;B\x07",
        .clock = .{ .real_ms = 100, .awake_ns = 1000 },
    }, &collected);
    _ = tracker.input("echo hi\r\n");
    tracker.feed(.{
        .bytes = "\x1b]133;C\x07",
        .clock = .{ .real_ms = 150, .awake_ns = 1000 },
    }, &collected);
    tracker.feed(.{
        .bytes = "hi\r\n\x1b]133;D;0\x07",
        .clock = .{ .real_ms = 200, .awake_ns = 51_000 },
    }, &collected);

    try std.testing.expectEqual(@as(usize, 1), collected.count);
    try std.testing.expectEqualStrings("echo hi\r\n", collected.last.?.bytes);
    try std.testing.expectEqualStrings("/work", collected.last.?.cwd);
    try std.testing.expectEqual(@as(?i32, 0), collected.last.?.exit_code);
    try std.testing.expectEqual(@as(i64, 50_000), collected.last.?.duration_ns);
}

test "updates cwd from OSC 7 and reports interrupted commands" {
    var tracker = Tracker.init("/old");
    var collected: Collected = .{};
    tracker.feed(.{
        .bytes = "\x1b]7;file://host/tmp/a%20b\x07\x1b]133;B\x07",
        .clock = .{ .real_ms = 20, .awake_ns = 100 },
    }, &collected);
    _ = tracker.input("make\r\n");
    tracker.feed(.{
        .bytes = "\x1b]133;C\x07",
        .clock = .{ .real_ms = 20, .awake_ns = 100 },
    }, &collected);
    tracker.interrupt(.{ .real_ms = 25, .awake_ns = 500 }, &collected);

    try std.testing.expectEqual(@as(usize, 1), collected.count);
    try std.testing.expectEqualStrings("/tmp/a b", collected.last.?.cwd);
    try std.testing.expectEqual(Status.interrupted, collected.last.?.status);
    try std.testing.expect(collected.last.?.exit_code == null);
}

test "an oversized OSC does not prevent later markers" {
    var tracker = Tracker.init("/");
    var collected: Collected = .{};
    var oversized: [max_osc_bytes + 64]u8 = @splat('x');
    tracker.feed(.{ .bytes = "\x1b]", .clock = .{ .real_ms = 0, .awake_ns = 0 } }, &collected);
    tracker.feed(.{ .bytes = &oversized, .clock = .{ .real_ms = 0, .awake_ns = 0 } }, &collected);
    tracker.feed(.{
        .bytes = "\x07\x1b]133;B\x07",
        .clock = .{ .real_ms = 1, .awake_ns = 10 },
    }, &collected);
    _ = tracker.input("pwd\r\n");
    tracker.feed(.{
        .bytes = "\x1b]133;C\x07\x1b]133;D;7\x07",
        .clock = .{ .real_ms = 1, .awake_ns = 10 },
    }, &collected);
    try std.testing.expectEqual(@as(usize, 1), collected.count);
    try std.testing.expectEqual(@as(?i32, 7), collected.last.?.exit_code);
}
