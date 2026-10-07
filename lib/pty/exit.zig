//! Value describing how a pane's child process terminated.

const std = @import("std");

pub const Exit = union(enum) {
    exited: u8,
    signaled: std.posix.SIG,

    /// Maps normal exits and signals to the status convention used by shells.
    ///
    /// ```zig
    /// const status = exit.code();
    /// ```
    pub fn code(self: Exit) u8 {
        return switch (self) {
            .exited => |status| status,
            .signaled => |signal| @intCast(@min(128 + @intFromEnum(signal), std.math.maxInt(u8))),
        };
    }
};
