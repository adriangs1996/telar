const ResizeWatcher = @This();
const source_namespace = @import("posix.zig");
const Tty = @import("PosixTty.zig");
const std = @import("std");
read_end: source_namespace.File,

pub fn init(_: *Tty) !ResizeWatcher {
    if (std.c.pipe(&source_namespace.wake) != 0) {
        return error.PipeFailed;
    }
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = source_namespace.onWinch },
        .mask = std.posix.sigemptyset(),
        // Without RESTART every blocking read in the program returns EINTR
        // on every resize, and each caller has to remember to retry.
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &action, null);
    return .{ .read_end = .{ .handle = source_namespace.wake[0], .flags = .{ .nonblocking = false } } };
}

pub fn deinit(w: *ResizeWatcher) void {
    // Disarmed before the descriptors close, so a signal arriving during
    // shutdown cannot write into a number that has already been recycled
    // by whatever opened next.
    const write_end = source_namespace.wake[1];
    source_namespace.wake[1] = -1;
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
pub fn wait(w: *ResizeWatcher, io: source_namespace.Io) source_namespace.Io.Cancelable!void {
    var drain: [64]u8 = undefined;
    _ = w.read_end.readStreaming(io, &.{&drain}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        // The pipe is ours and nothing else writes to it, so any other
        // failure means shutdown. Returning leaves the caller's loop.
        else => return,
    };
}
