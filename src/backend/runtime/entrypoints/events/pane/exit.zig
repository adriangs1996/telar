const std = @import("std");
const exit_module = @import("../../../../pty/exit.zig");

pub fn exitOrSynthetic(result: anyerror!exit_module.Exit) exit_module.Exit {
    return result catch .{ .signaled = .KILL };
}

test "wait failure becomes a synthetic SIGKILL exit" {
    try std.testing.expectEqual(
        exit_module.Exit{ .signaled = .KILL },
        exitOrSynthetic(error.WaitpidFailed),
    );
    try std.testing.expectEqual(
        exit_module.Exit{ .exited = 7 },
        exitOrSynthetic(exit_module.Exit{ .exited = 7 }),
    );
}
