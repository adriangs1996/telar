const std = @import("std");
const PosixTty = @import("PosixTty.zig");
const posix_ops = @import("posix.zig");
const ResizeWatcher = @This();

read_end: std.Io.File,

pub fn init(_: *PosixTty) !ResizeWatcher {
    if (std.c.pipe(&posix_ops.wake) != 0) {
        return error.PipeFailed;
    }
    var action: std.posix.Sigaction = .{
        .handler = .{ .handler = posix_ops.onWinch },
        .mask = std.posix.sigemptyset(),
        // Without RESTART every blocking read in the program returns EINTR
        // on every resize, and each caller has to remember to retry.
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(.WINCH, &action, null);
    return .{ .read_end = .{ .handle = posix_ops.wake[0], .flags = .{ .nonblocking = false } } };
}

pub fn deinit(w: *ResizeWatcher) void {
    // Disarmed before the descriptors close, so a signal arriving during
    // shutdown cannot write into a number that has already been recycled
    // by whatever opened next.
    const write_end = posix_ops.wake[1];
    posix_ops.wake[1] = -1;
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
pub fn wait(w: *ResizeWatcher, io: std.Io) std.Io.Cancelable!void {
    var drain: [64]u8 = undefined;
    _ = w.read_end.readStreaming(io, &.{&drain}) catch |err| switch (err) {
        error.Canceled => |e| return e,
        // The pipe is ours and nothing else writes to it, so any other
        // failure means shutdown. Returning leaves the caller's loop.
        else => return,
    };
}
