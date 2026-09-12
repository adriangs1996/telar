const PosixFastWriter = @import("PosixFastWriter.zig");
const PosixTty = @import("PosixTty.zig");

const LocalTime = @import("telar-client").LocalTime;
const std = @import("std");
const sequences = @import("sequences.zig");

const time = @cImport({
    @cInclude("time.h");
});
pub const unistd = @cImport({
    @cInclude("unistd.h");
});

pub fn localTime() LocalTime {
    var seconds: time.time_t = 0;
    if (time.time(&seconds) == -1) {
        return fallbackLocalTime();
    }

    var local: time.struct_tm = undefined;
    if (time.localtime_r(&seconds, &local) == null) {
        return fallbackLocalTime();
    }

    return .{
        .year = @intCast(local.tm_year + 1900),
        .month = @intCast(local.tm_mon + 1),
        .day = @intCast(local.tm_mday),
        .hour = @intCast(local.tm_hour),
        .minute = @intCast(local.tm_min),
        .second = @intCast(local.tm_sec),
        .weekday = @intCast(local.tm_wday),
    };
}

fn fallbackLocalTime() LocalTime {
    return .{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .weekday = 4 };
}

// Unix: termios for the mode, an ioctl for the size, SIGWINCH for the change.

pub const FastWriter = @import("PosixFastWriter.zig");

pub const Tty = @import("PosixTty.zig");

pub fn nonzeroHash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x74656c61722d7474, bytes) | 1;
}

/// What the fatal-signal handler needs to put the terminal back, captured
/// when the client installs it. A panic does not run `defer`s - it aborts -
/// so without this every crash leaves the terminal raw, on the alternate
/// screen, with mouse reporting on, and the panic message itself lands
/// somewhere the user cannot read it.
pub var crash_restore: struct {
    fd: std.c.fd_t = -1,
    original: std.posix.termios = undefined,
    leave: []const u8 = "",
} = .{};

/// Arms the fatal-signal restore for this terminal. Zig's panic path ends in
/// `abort`, so catching SIGABRT (plus the hardware faults) covers panics as
/// well as genuine crashes. The handler defers to the default disposition
/// afterwards, so exit status and core dumps are unchanged.
pub fn installCrashRestore(t: *const PosixTty) void {
    crash_restore = .{
        .fd = t.fd,
        .original = t.original,
        .leave = sequences.leave,
    };
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = std.posix.sigemptyset(),
        // RESETHAND: one shot, then the default disposition. A second fault
        // inside the handler must not recurse.
        .flags = std.posix.SA.RESETHAND,
    };
    for ([_]std.posix.SIG{ .ABRT, .SEGV, .BUS, .ILL, .FPE, .TRAP }) |signal| {
        std.posix.sigaction(signal, &action, null);
    }
}

/// The restore the fatal-signal handler performs. Only async-signal-safe
/// calls - `write` and `tcsetattr` are both on the POSIX list - and safe to
/// run any number of times, because a crash path cannot be choosy about who
/// already ran it.
pub fn emergencyRestore() void {
    const state = crash_restore;
    if (state.fd < 0) {
        return;
    }
    _ = std.c.write(state.fd, state.leave.ptr, state.leave.len);
    std.posix.tcsetattr(state.fd, .FLUSH, state.original) catch {};
}

fn onFatalSignal(signal: std.posix.SIG) callconv(.c) void {
    emergencyRestore();
    // RESETHAND already restored the default disposition; re-raising delivers
    // the original signal to it once the handler returns.
    _ = std.c.raise(signal);
}

test "fast output attempts at most 4 KiB and yields on a full descriptor" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer _ = std.c.close(fds[0]);
    var fast: PosixFastWriter = .{ .fd = fds[1] };
    defer fast.deinit();
    const flags = std.posix.O{ .NONBLOCK = true };
    try std.testing.expect(std.c.fcntl(fast.fd, std.posix.F.SETFL, @as(c_int, @bitCast(flags))) == 0);
    const bytes = [_]u8{0x34} ** 8192;
    try std.testing.expectEqual(@as(usize, 4096), try PosixFastWriter.writeOpaque(&fast, &bytes));
    for (0..1024) |_| {
        if (try PosixFastWriter.writeOpaque(&fast, &bytes) == 0) {
            return;
        }
    }
    return error.PipeNeverReachedBackpressure;
}

test "emergency restore is armed, idempotent, and disarmable" {
    // Unarmed: a no-op with nowhere to write.
    emergencyRestore();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer _ = std.c.close(fds[0]);

    crash_restore = .{
        .fd = fds[1],
        .original = std.mem.zeroes(std.posix.termios),
        .leave = sequences.leave,
    };
    // Twice: the crash path cannot be choosy about who already ran it, and
    // the tcsetattr on a pipe failing must stay silent.
    emergencyRestore();
    emergencyRestore();
    crash_restore.fd = -1;
    _ = std.c.close(fds[1]);

    var buffer: [4 * sequences.leave.len]u8 = undefined;
    const got = std.c.read(fds[0], &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, 2 * sequences.leave.len), got);
    try std.testing.expectEqualStrings(
        sequences.leave ++ sequences.leave,
        buffer[0..@intCast(got)],
    );

    // Disarmed: a no-op again.
    emergencyRestore();
}

/// The self-pipe SIGWINCH writes into.
///
/// A signal handler may call almost nothing - not an allocator, not a mutex,
/// not a queue - so it does the one thing that is defined: write a byte to a
/// descriptor. That turns an asynchronous signal into an ordinary readable
/// file, which the rest of the program already knows how to wait on.
pub var wake: [2]std.c.fd_t = .{ -1, -1 };

pub fn onWinch(_: std.posix.SIG) callconv(.c) void {
    if (wake[1] >= 0) {
        _ = std.c.write(wake[1], "!", 1);
    }
}

pub const ResizeWatcher = @import("PosixResizeWatcher.zig");
