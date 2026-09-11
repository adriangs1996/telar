const FastWriter = @This();
const std = @import("std");
fd: std.c.fd_t,

/// Opens an independent nonblocking description of the controlling tty.
/// Example: `var fast = FastWriter.open() orelse return;`.
pub fn open() ?FastWriter {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/tty", .{
        .ACCMODE = .WRONLY,
        .NONBLOCK = true,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0) catch return null;
    return .{ .fd = fd };
}

/// Attempts one bounded write. A full tty queue falls back to the actor.
/// Example: `const count = try FastWriter.writeOpaque(&fast, bytes);`.
pub fn writeOpaque(context: *anyopaque, bytes: []const u8) !usize {
    const fast: *FastWriter = @ptrCast(@alignCast(context));
    const result = std.c.write(fast.fd, bytes.ptr, @min(bytes.len, 4096));
    if (result >= 0) {
        return @intCast(result);
    }

    return switch (std.posix.errno(result)) {
        .AGAIN, .INTR => 0,
        else => error.WriteFailed,
    };
}

/// Closes after the client has joined its host-output actor.
/// Example: `fast.deinit();`.
pub fn deinit(fast: *FastWriter) void {
    _ = std.c.close(fast.fd);
}
