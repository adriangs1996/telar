//! Bounded external command worker for configured bar and panel sources
//! and for pick lists. A command runs in its own process group and its
//! timeout bounds the whole run, from spawn to exit: a command that prints
//! a byte now and then still stops at its deadline, and a command that
//! outlives it is stopped with its group, TERM first and KILL after a
//! grace period. A command that exits in time keeps its group alive, so a
//! helper may leave work running in the background on purpose.

const data = @import("model");
const std = @import("std");
const Output = @import("Output.zig");
const builtin = @import("builtin");

const stderr_limit = 4096;
const tab: u8 = '\t';
const line_feed: u8 = '\n';
const carriage_return: u8 = '\r';
const first_printable: u8 = 0x20;
const delete_control: u8 = 0x7f;
/// Bytes a read asks room for before waiting on the pipes again.
const read_reserve = 4096;
/// How long a group gets to leave after TERM, and after KILL.
const grace_ms = 200;
const kill_wait_ms = 1000;
/// How often a wait for the exit checks the process again.
const poll_interval_ms = 2;

/// What the caller does with a command's standard output.
pub const OutputUse = enum {
    /// Shown as plain text: one display line.
    line,
    /// Handed to a callback: several lines.
    lines,
    /// The options of a pick list: several lines, with more room.
    options,
    /// Only the exit status matters, as for a pick's `on_select`. Output
    /// goes to `/dev/null`, so no amount of it fails the command.
    ignored,

    fn limit(self: OutputUse) usize {
        return switch (self) {
            .line => data.bar_values.max_text_bytes + 2,
            .lines => data.bar_values.max_command_output_bytes,
            .options => data.bar_values.max_pick_output_bytes,
            .ignored => 0,
        };
    }
};

/// Runs a bar or panel source. Output handed to a render callback may hold
/// several lines, up to `max_command_output_bytes`; output shown as plain
/// text must be one display line of `max_text_bytes`.
///
/// ```zig
/// var output = try command.run(io, bar_command);
/// defer output.deinit();
/// ```
pub fn run(io: std.Io, command: data.BarCommand) !Output {
    return runFor(io, command, if (command.render != null) .lines else .line);
}

/// Runs the argv directly, without a shell, stops it at its deadline, and
/// validates its output for `use`.
///
/// ```zig
/// var output = try command.runFor(io, on_select, .ignored);
/// defer output.deinit();
/// ```
pub fn runFor(io: std.Io, command: data.BarCommand, use: OutputUse) !Output {
    var argument_storage: [data.bar_values.max_command_args][]const u8 = undefined;
    const argv = command.argumentSlice(&argument_storage);
    if (argv.len == 0) {
        return error.EmptyBarCommand;
    }

    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(command.timeout_ms),
    });
    const captured = use != .ignored;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = if (captured) .pipe else .ignore,
        .stderr = if (captured) .pipe else .ignore,
        .pgid = if (process_groups) 0 else null,
    });
    defer stop(io, &child);

    var output: Output = .{};
    errdefer output.deinit();
    if (captured) {
        output.buffer = try read(io, &child, .{
            .limit = use.limit(),
            .deadline = deadline,
        });
    }

    if (try waitUntil(io, &child, deadline) != 0) {
        return error.BarCommandFailed;
    }

    if (!captured) {
        return output;
    }

    const rendered = use != .line;
    const trimmed = std.mem.trim(u8, output.buffer, " \t\r\n");
    if (!rendered and trimmed.len > data.bar_values.max_text_bytes) {
        return error.BarCommandOutputTooLong;
    }

    for (trimmed) |byte| {
        const line_break = byte == line_feed or byte == carriage_return or byte == tab;
        if (line_break and rendered) {
            continue;
        }

        if (byte < first_printable or byte == delete_control) {
            return error.InvalidBarCommandOutput;
        }
    }

    if (!std.unicode.utf8ValidateSlice(trimmed)) {
        return error.InvalidBarCommandOutput;
    }

    output.start = @intFromPtr(trimmed.ptr) - @intFromPtr(output.buffer.ptr);
    output.len = trimmed.len;
    return output;
}

const process_groups = builtin.os.tag != .windows;

const ReadLimits = struct {
    limit: usize,
    deadline: std.Io.Clock.Timestamp,
};

// Reads stdout and a bounded stderr until both close or the deadline
// passes; the deadline is absolute, so steady trickles of output cannot
// extend it. Returns stdout, owned by `Output.allocator`.
fn read(io: std.Io, child: *std.process.Child, limits: ReadLimits) ![]u8 {
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(Output.allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const deadline: std.Io.Timeout = .{
        .deadline = limits.deadline,
    };
    while (multi_reader.fill(read_reserve, deadline)) |_| {
        if (stdout_reader.buffered().len > limits.limit or stderr_reader.buffered().len > stderr_limit) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }

    try multi_reader.checkAnyError();
    return multi_reader.toOwnedSlice(0);
}

// Waits for the process to exit without passing the deadline and returns
// its exit status; a process a signal ended fails. The pipes are closed
// once it is reaped.
fn waitUntil(io: std.Io, child: *std.process.Child, deadline: std.Io.Clock.Timestamp) !u8 {
    if (!process_groups) {
        return switch (try child.wait(io)) {
            .exited => |status| status,
            else => error.BarCommandFailed,
        };
    }

    while (true) {
        switch (reap(io, child)) {
            .running => {},
            .exited => |status| return status,
            .ended => return error.BarCommandFailed,
        }

        if (deadline.durationFromNow(io).raw.nanoseconds <= 0) {
            return error.Timeout;
        }

        try std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake);
    }
}

/// How a check for the process's exit went.
const Exit = union(enum) {
    running,
    exited: u8,
    /// A signal ended it, or it was already collected.
    ended,
};

// Collects the process if it exited, without blocking.
fn reap(io: std.Io, child: *std.process.Child) Exit {
    const pid = child.id orelse return .ended;
    var status: if (builtin.link_libc) c_int else u32 = 0;
    while (true) {
        const result = std.posix.system.wait4(pid, &status, std.posix.W.NOHANG, null);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result != pid) {
                    return .running;
                }

                release(io, child);
                const raw: u32 = @bitCast(status);
                if (!std.posix.W.IFEXITED(raw)) {
                    return .ended;
                }

                return .{
                    .exited = std.posix.W.EXITSTATUS(raw),
                };
            },
            .INTR => continue,
            else => {
                release(io, child);
                return .ended;
            },
        }
    }
}

// Stops a process that is still running when the run ends early: TERM to
// its group, KILL after the grace period, and a bounded wait for it. A
// process that ignores even KILL is left unreaped rather than blocking the
// worker.
fn stop(io: std.Io, child: *std.process.Child) void {
    if (child.id == null) {
        return;
    }

    if (!process_groups) {
        return child.kill(io);
    }

    const group = -child.id.?;
    std.posix.kill(group, .TERM) catch {};
    if (settle(io, child, grace_ms)) {
        return;
    }

    std.posix.kill(group, .KILL) catch {};
    if (!settle(io, child, kill_wait_ms)) {
        release(io, child);
    }
}

fn settle(io: std.Io, child: *std.process.Child, milliseconds: u32) bool {
    var waited: u32 = 0;
    while (waited < milliseconds) : (waited += poll_interval_ms) {
        if (reap(io, child) != .running) {
            return true;
        }

        std.Io.sleep(io, .fromMilliseconds(poll_interval_ms), .awake) catch return false;
    }

    return reap(io, child) != .running;
}

// Closes the pipes of a process no longer waited for, as `Child.wait` does.
fn release(io: std.Io, child: *std.process.Child) void {
    if (child.stdout) |file| {
        file.close(io);
        child.stdout = null;
    }

    if (child.stderr) |file| {
        file.close(io);
        child.stderr = null;
    }

    child.id = null;
}

test "command runner executes argv directly and validates one display line" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var command: data.BarCommand = .{
        .generation = 1,
        .interval_ns = std.time.ns_per_s,
        .timeout_ms = 1_000,
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument("printf 'quota 74%%\\n'");

    var output = try run(std.testing.io, command);
    defer output.deinit();

    try std.testing.expectEqualStrings("quota 74%", output.slice());

    var invalid = command;
    invalid.argument_count = 0;
    invalid.byte_len = 0;
    try invalid.appendArgument("/bin/sh");
    try invalid.appendArgument("-c");
    try invalid.appendArgument("printf 'first\\nsecond\\n'");

    try std.testing.expectError(error.InvalidBarCommandOutput, run(std.testing.io, invalid));
}

test "ignored output needs only a successful exit and a failure keeps its status" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var command: data.BarCommand = .{
        .generation = 1,
        .interval_ns = 0,
        .timeout_ms = 1_000,
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument("printf '\\033[1mdone\\n\\n'");

    var output = try runFor(std.testing.io, command, .ignored);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 0), output.slice().len);

    var failing = command;
    failing.argument_count = 0;
    failing.byte_len = 0;
    try failing.appendArgument("/bin/sh");
    try failing.appendArgument("-c");
    try failing.appendArgument("exit 3");
    try std.testing.expectError(error.BarCommandFailed, runFor(std.testing.io, failing, .ignored));
}

test "the timeout bounds the whole run of a command that keeps printing" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    const command = try testCommand(300, "while :; do printf x; sleep 0.05; done");
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(error.Timeout, runFor(std.testing.io, command, .lines));
    try expectWithin(started, 2_000);
}

test "a command that ignores TERM is killed with its group after the grace period" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temp.dir.realPathFile(std.testing.io, ".", &path_buffer);
    const directory = path_buffer[0..len];

    // The shell ignores TERM, and its grandchild records its pid and
    // outlives it unless the whole group is killed.
    var script_buffer: [std.fs.max_path_bytes + 128]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buffer, "trap '' TERM; sleep 30 & echo $! > {s}/grandchild; wait", .{directory});
    for ([_]OutputUse{ .lines, .ignored }) |use| {
        const command = try testCommand(200, script);
        const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
        try std.testing.expectError(error.Timeout, runFor(std.testing.io, command, use));
        try expectWithin(started, 3_000);

        var pid_buffer: [32]u8 = undefined;
        const text = try temp.dir.readFile(std.testing.io, "grandchild", &pid_buffer);
        const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \n"), 10);
        try expectGone(pid);
    }
}

test "ignored output never fails a command that exits cleanly" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    const command = try testCommand(5_000, "head -c 1048576 /dev/zero; head -c 65536 /dev/zero >&2");
    var output = try runFor(std.testing.io, command, .ignored);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 0), output.slice().len);
}

fn testCommand(timeout_ms: u32, script: []const u8) !data.BarCommand {
    var command: data.BarCommand = .{
        .generation = 1,
        .interval_ns = 0,
        .timeout_ms = timeout_ms,
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument(script);
    return command;
}

fn expectWithin(started: std.Io.Clock.Timestamp, milliseconds: i96) !void {
    const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake));
    try std.testing.expect(elapsed.raw.nanoseconds < milliseconds * std.time.ns_per_ms);
}

// A killed process may linger as a zombie of its reaper for a moment.
fn expectGone(pid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }

    return error.TestProcessStillRunning;
}

test "command output for a render callback may span lines" {
    if (comptime builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }

    var command: data.BarCommand = .{
        .generation = 1,
        .interval_ns = std.time.ns_per_s,
        .timeout_ms = 1_000,
        .render = .{ .generation = 1, .id = 0 },
    };
    try command.appendArgument("/bin/sh");
    try command.appendArgument("-c");
    try command.appendArgument("printf '{\\n  \"used\": 22\\n}\\n'");

    var output = try run(std.testing.io, command);
    defer output.deinit();

    try std.testing.expectEqualStrings("{\n  \"used\": 22\n}", output.slice());
}
