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
    pub fn code(exit: Exit) u8 {
        return switch (exit) {
            .exited => |status| status,
            .signaled => |signal| @intCast(@min(128 + @intFromEnum(signal), std.math.maxInt(u8))),
        };
    }
};

test "the process result maps to the conventional shell status" {
    try std.testing.expectEqual(@as(u8, 7), (Exit{ .exited = 7 }).code());
    try std.testing.expectEqual(
        @as(u8, 128 + @intFromEnum(std.posix.SIG.TERM)),
        (Exit{ .signaled = .TERM }).code(),
    );
}
