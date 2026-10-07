//! Bounded external command worker for configured bar and panel sources
//! and for pick lists. A command runs in its own process group and its
//! timeout bounds the whole run, from spawn to exit: a command that prints
//! a byte now and then still stops at its deadline, and a command that
//! outlives it is stopped with its group, TERM first and KILL after a
//! grace period. A command that exits in time keeps its group alive, so a
//! helper may leave work running in the background on purpose.

const core = @import("telar-core");
const data = @import("model");
const std = @import("std");
const Output = @import("Output.zig");
const builtin = @import("builtin");

/// Standard error a captured command keeps; nothing shows it, so what it
/// prints past this is dropped without a report and never fails it.
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

    /// The limit a command reports when it prints more than `limit`.
    fn named(self: OutputUse) core.Limit {
        return switch (self) {
            .line, .ignored => data.bar_values.text_limit,
            .lines => data.bar_values.command_output_limit,
            .options => data.bar_values.pick_output_limit,
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
/// validates its output for `use`. Output past its limit is dropped: the
/// kept output ends at the last whole line (or, for one display line, at a
/// character) and `Output.limit` names the limit for the finishing flow to
/// report.
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
    var full = false;
    if (captured) {
        output.buffer = try read(io, &child, .{
            .limit = use.limit(),
            .deadline = deadline,
            .full = &full,
        });
    }

    // A command that filled what is kept is stopped now, by the deferred
    // stop, instead of printing on until its deadline; its exit status no
    // longer matters.
    if (!full and try waitUntil(io, &child, deadline) != 0) {
        return error.BarCommandFailed;
    }

    if (!captured) {
        return output;
    }

    const rendered = use != .line;
    const printed = output.buffer.len;
    var cut = full;
    const held = output.buffer[0..@min(output.buffer.len, use.limit())];
    const kept = if (cut and rendered) wholeLines(held) else held;
    var trimmed = std.mem.trim(u8, kept, " \t\r\n");
    if (!rendered and trimmed.len > data.bar_values.max_text_bytes) {
        trimmed = data.bar_text.prefix(trimmed, data.bar_values.max_text_bytes);
        cut = true;
    }

    if (cut) {
        output.limit = .{
            .limit = use.named(),
            .requested = printed,
        };
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
    /// Set when stdout printed past `limit` and reading stopped.
    full: *bool,
};

// Reads stdout and a bounded stderr until both close, the deadline passes
// or stdout prints past its limit; the deadline is absolute, so steady
// trickles of output cannot extend it. Standard error is dropped as it
// passes its limit, since nothing shows it. Returns stdout, owned by
// `Output.allocator`, which may hold a little more than the limit when it
// is full.
fn read(io: std.Io, child: *std.process.Child, limits: ReadLimits) ![]u8 {
    // SAFETY: toStreams sets the count; MultiReader.init fills both contexts and initializes the operation batch before use.
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    // SAFETY: init constructs the reader in place before reads or deferred deinit.
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(Output.allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const deadline: std.Io.Timeout = .{
        .deadline = limits.deadline,
    };
    while (multi_reader.fill(read_reserve, deadline)) |_| {
        const noise = stderr_reader.bufferedLen();
        if (noise > stderr_limit) {
            stderr_reader.toss(noise);
        }

        if (stdout_reader.bufferedLen() > limits.limit) {
            limits.full.* = true;
            return multi_reader.toOwnedSlice(0);
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |other| return other,
    }

    try multi_reader.checkAnyError();
    return multi_reader.toOwnedSlice(0);
}

// The output up to its last line feed, so a cut never leaves half a line
// or half a character.
fn wholeLines(output: []const u8) []const u8 {
    const last = std.mem.lastIndexOfScalar(u8, output, line_feed) orelse return output[0..0];
    return output[0..last];
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
    // The process group may have exited before signaling; settle still observes and reaps the child.
    std.posix.kill(group, .TERM) catch {};
    if (settle(io, child, grace_ms)) {
        return;
    }

    // The process group may already be gone; settle and release below still finish child ownership.
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
