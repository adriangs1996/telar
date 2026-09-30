//! A CLI command at one of telar's limits. It has no model and no window,
//! so it keeps what fit, prints the limit notice on standard error and the
//! command exits nonzero. See `docs/flows/limit-reached.md`.
const builtin = @import("builtin");
const core = @import("telar-core");
const std = @import("std");

/// Prints the notice of one reached limit on standard error.
///
/// ```zig
/// limit_reached.report(.{ .limit = git_timeout_limit });
/// // telar: Limit reached: worktrees.git_timeout: limit 300 seconds reached
/// ```
pub fn report(reach: core.LimitReach) void {
    // The test runner reads a test's standard error as a failure.
    if (builtin.is_test) {
        return;
    }

    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    std.debug.print("telar: {s}: {s}\n", .{ core.limit_reached.notice_title, reach.describe(&buffer, 1) });
}

test "the notice names the limit, what was asked for and its value" {
    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    const reach: core.LimitReach = .{
        .limit = core.Limit.declare("worktrees.git_listing_bytes", "bytes", 1024),
        .requested = 2048,
    };

    try std.testing.expectEqualStrings("worktrees.git_listing_bytes: 2048 bytes; limit 1024", reach.describe(&buffer, 1));
}
