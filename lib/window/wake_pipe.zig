const std = @import("std");

const c = @cImport({
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

pub fn isReadable(fd: c_int) bool {
    const flags = c.fcntl(fd, c.F_GETFL);
    return flags >= 0 and flags & c.O_ACCMODE != c.O_WRONLY;
}

/// Consumes at most one buffer of wake bytes without changing the borrowed fd's
/// flags. The window is its sole reader. Poll before read also supports blocking
/// pipes; a bounded read lets native events progress during a producer flood.
/// EOF is an error, otherwise a closed writer would keep waking an idle loop.
pub fn take(fd: c_int) !bool {
    var descriptor: c.pollfd = .{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    while (true) {
        const result = c.poll(&descriptor, 1, 0);
        if (result >= 0) {
            if (result == 0) {
                return false;
            }

            break;
        }

        if (std.posix.errno(result) != .INTR) {
            return error.WakeReadFailed;
        }
    }

    if (descriptor.revents & c.POLLNVAL != 0) {
        return error.InvalidWakeDescriptor;
    }

    if (descriptor.revents & c.POLLIN != 0) {
        var bytes: [256]u8 = undefined;
        while (true) {
            const count = c.read(fd, &bytes, bytes.len);
            if (count > 0) {
                return true;
            }

            if (count == 0) {
                return error.WakeDescriptorClosed;
            }

            switch (std.posix.errno(count)) {
                .INTR => continue,
                .AGAIN => return false,
                else => return error.WakeReadFailed,
            }
        }
    }

    return error.WakeDescriptorClosed;
}
