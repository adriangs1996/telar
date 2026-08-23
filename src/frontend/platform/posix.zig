const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const File = Io.File;

const platform = @import("../platform.zig");
const Size = platform.Size;

// Unix: termios for the mode, an ioctl for the size, SIGWINCH for the change.

pub const Tty = struct {
    fd: std.c.fd_t,
    original: std.posix.termios,

    /// Opens the controlling terminal directly rather than using stdin.
    ///
    /// stdin may be a pipe - the program could have been started from a script
    /// or with its input redirected - and putting a pipe into raw mode fails
    /// while telling you nothing about the terminal the user is looking at.
    /// `/dev/tty` is the session's terminal whatever the descriptors point at.
    pub fn open() !Tty {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        }, 0);
        errdefer _ = std.c.close(fd);

        const original = try std.posix.tcgetattr(fd);
        var raw = original;

        // Canonical mode buffers until a newline, echo prints what is typed,
        // and signal generation turns Ctrl+C into a signal instead of a byte.
        // A full screen application wants all three off and every byte itself.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .original = original };
    }

    pub fn deinit(t: *Tty) void {
        // Disarmed before the descriptor closes, so a crash after shutdown
        // cannot write escape sequences into a recycled file descriptor.
        crash_restore.fd = -1;
        std.posix.tcsetattr(t.fd, .FLUSH, t.original) catch {};
        _ = std.c.close(t.fd);
    }

    pub fn size(t: *const Tty) Size {
        var ws: std.posix.winsize = undefined;
        const TIOCGWINSZ: c_int = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => 0x40087468,
            .linux => 0x5413,
            .freebsd, .netbsd, .openbsd, .dragonfly => 0x40087468,
            else => @compileError("no TIOCGWINSZ for this target"),
        };
        // A terminal that will not answer is not a reason to abort. Eighty by
        // twenty-four is what every terminal since 1978 has defaulted to, and
        // a wrong size draws a wrong frame where a crash draws nothing.
        if (std.c.ioctl(t.fd, TIOCGWINSZ, &ws) != 0) return .{ .cols = 80, .rows = 24 };
        return .{
            .cols = ws.col,
            .rows = ws.row,
            .width_px = ws.xpixel,
            .height_px = ws.ypixel,
        };
    }

    pub fn writeHandle(t: *const Tty) File {
        return .{ .handle = t.fd, .flags = .{ .nonblocking = false } };
    }

    pub fn readHandle(t: *const Tty) File {
        return .{ .handle = t.fd, .flags = .{ .nonblocking = false } };
    }
};

/// What the fatal-signal handler needs to put the terminal back, captured
/// when the client installs it. A panic does not run `defer`s - it aborts -
/// so without this every crash leaves the terminal raw, on the alternate
/// screen, with mouse reporting on, and the panic message itself lands
/// somewhere the user cannot read it.
var crash_restore: struct {
    fd: std.c.fd_t = -1,
    original: std.posix.termios = undefined,
    leave: []const u8 = "",
} = .{};

/// Arms the fatal-signal restore for this terminal. Zig's panic path ends in
/// `abort`, so catching SIGABRT (plus the hardware faults) covers panics as
/// well as genuine crashes. The handler defers to the default disposition
/// afterwards, so exit status and core dumps are unchanged.
pub fn installCrashRestore(t: *const Tty) void {
    crash_restore = .{
        .fd = t.fd,
        .original = t.original,
        .leave = platform.leave_sequence,
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
    if (state.fd < 0) return;
    _ = std.c.write(state.fd, state.leave.ptr, state.leave.len);
    std.posix.tcsetattr(state.fd, .FLUSH, state.original) catch {};
}

fn onFatalSignal(signal: std.posix.SIG) callconv(.c) void {
    emergencyRestore();
    // RESETHAND already restored the default disposition; re-raising delivers
    // the original signal to it once the handler returns.
    _ = std.c.raise(signal);
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
        .leave = platform.leave_sequence,
    };
    // Twice: the crash path cannot be choosy about who already ran it, and
    // the tcsetattr on a pipe failing must stay silent.
    emergencyRestore();
    emergencyRestore();
    crash_restore.fd = -1;
    _ = std.c.close(fds[1]);

    var buffer: [4 * platform.leave_sequence.len]u8 = undefined;
    const got = std.c.read(fds[0], &buffer, buffer.len);
    try std.testing.expectEqual(@as(isize, 2 * platform.leave_sequence.len), got);
    try std.testing.expectEqualStrings(
        platform.leave_sequence ++ platform.leave_sequence,
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
var wake: [2]std.c.fd_t = .{ -1, -1 };

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    if (wake[1] >= 0) _ = std.c.write(wake[1], "!", 1);
}

pub const ResizeWatcher = struct {
    read_end: File,

    pub fn init(_: *Tty) !ResizeWatcher {
        if (std.c.pipe(&wake) != 0) return error.PipeFailed;
        var action: std.posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = std.posix.sigemptyset(),
            // Without RESTART every blocking read in the program returns EINTR
            // on every resize, and each caller has to remember to retry.
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.WINCH, &action, null);
        return .{ .read_end = .{ .handle = wake[0], .flags = .{ .nonblocking = false } } };
    }

    pub fn deinit(w: *ResizeWatcher) void {
        // Disarmed before the descriptors close, so a signal arriving during
        // shutdown cannot write into a number that has already been recycled
        // by whatever opened next.
        const write_end = wake[1];
        wake[1] = -1;
        _ = std.c.close(write_end);
        _ = std.c.close(w.read_end.handle);
    }

    /// Blocks until a resize arrives.
    ///
    /// `File.readStreaming` and not `std.c.read`, and the difference is the
    /// whole shutdown path: cancelling a task interrupts an `Io` operation and
    /// a raw syscall is not one. An actor blocked in libc's `read` never
    /// notices it was cancelled, so the group waits for it forever and the
    /// process hangs with the terminal still in raw mode.
    pub fn wait(w: *ResizeWatcher, io: Io) Io.Cancelable!void {
        var drain: [64]u8 = undefined;
        _ = w.read_end.readStreaming(io, &.{&drain}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            // The pipe is ours and nothing else writes to it, so any other
            // failure means shutdown. Returning leaves the caller's loop.
            else => return,
        };
    }
};
