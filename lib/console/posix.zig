const std = @import("std");
const sequences = @import("sequences.zig");

pub const unistd = @cImport({
    @cInclude("unistd.h");
});

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
    // SAFETY: installCrashRestore supplies the saved termios before installing handlers; emergencyRestore returns while fd is negative.
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
    // Fatal-signal cleanup cannot recover or safely log a restoration failure; return so the original signal can terminate the process.
    std.posix.tcsetattr(state.fd, .FLUSH, state.original) catch {};
}

fn onFatalSignal(signal: std.posix.SIG) callconv(.c) void {
    emergencyRestore();
    // RESETHAND already restored the default disposition; re-raising delivers
    // the original signal to it once the handler returns.
    _ = std.c.raise(signal);
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
