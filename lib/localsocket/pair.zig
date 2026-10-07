//! Two connected Unix stream sockets, for a channel whose other end is a
//! child process's standard input and output.

const SocketChannel = @import("SocketChannel.zig");
const builtin = @import("builtin");
const std = @import("std");

/// Creates the pair close-on-exec, so a process spawned later by another
/// thread never holds an end open past its owner. Where socketpair(2)
/// cannot take the flag (Darwin), each end gets it right after.
///
/// ```zig
/// const ends = try localsocket.pair();
/// ```
pub fn pair() ![2]SocketChannel {
    const flags: c_uint = std.c.SOCK.STREAM | if (builtin.os.tag == .linux) std.c.SOCK.CLOEXEC else 0;
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, flags, 0, &fds) != 0) {
        return switch (std.posix.errno(-1)) {
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => error.SystemResources,
            else => error.SocketFailed,
        };
    }
    errdefer {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
    }

    if (builtin.os.tag != .linux) {
        for (fds) |fd| {
            if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) != 0) {
                return error.SocketFailed;
            }
        }
    }

    return .{ channel(fds[0]), channel(fds[1]) };
}

fn channel(fd: std.c.fd_t) SocketChannel {
    return .init(.{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .loopback(0) },
    } });
}
