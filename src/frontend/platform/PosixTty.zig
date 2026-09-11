const std = @import("std");
const posix_ops = @import("posix.zig");
const Size = @import("Size.zig");
const builtin = @import("builtin");
const Tty = @This();

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
    posix_ops.crash_restore.fd = -1;
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
    if (std.c.ioctl(t.fd, TIOCGWINSZ, &ws) != 0) {
        return .{ .cols = 80, .rows = 24 };
    }
    return .{
        .cols = ws.col,
        .rows = ws.row,
        .width_px = ws.xpixel,
        .height_px = ws.ypixel,
    };
}

pub fn writeHandle(t: *const Tty) std.Io.File {
    return .{ .handle = t.fd, .flags = .{ .nonblocking = false } };
}

pub fn readHandle(t: *const Tty) std.Io.File {
    return .{ .handle = t.fd, .flags = .{ .nonblocking = false } };
}

/// Hashes the controlling terminal device into a reconnect-stable key.
///
/// ```zig
/// const identity = try tty.identity();
/// ```
pub fn identity(t: *const Tty) !u64 {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    if (posix_ops.unistd.ttyname_r(t.fd, &path, path.len) != 0) {
        return error.TerminalIdentityUnavailable;
    }

    const name = std.mem.sliceTo(&path, 0);
    if (name.len == 0) {
        return error.TerminalIdentityUnavailable;
    }

    return posix_ops.nonzeroHash(name);
}
