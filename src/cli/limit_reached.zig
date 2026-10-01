//! A CLI command at one of telar's limits. It has no model and no window,
//! so it keeps what fit, prints the limit notice on standard error and the
//! command exits nonzero. A command that holds a runtime session also
//! reports the reach, so the windows show it and `telar diagnostics limits`
//! lists it. See `docs/flows/limit-reached.md`.
const builtin = @import("builtin");
const core = @import("telar-core");
const std = @import("std");
const Session = @import("Session.zig");

/// The status a command exits with when a limit cost it data: what it kept
/// was done, but not all it was asked for.
pub const exit_status: u8 = 1;

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

/// Prints the notice like `report` and sends the reach through `session`.
/// Never fails: a report that cannot be sent still leaves the line on
/// standard error.
///
/// ```zig
/// limit_reached.reportThrough(&session, .{ .limit = input_limit, .requested = len });
/// ```
pub fn reportThrough(session: *Session, reach: core.LimitReach) void {
    report(reach);
    session.reportLimit(reach) catch {};
}

test "the notice names the limit, what was asked for and its value" {
    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    const reach: core.LimitReach = .{
        .limit = core.Limit.declare("worktrees.git_listing_bytes", "bytes", 1024),
        .requested = 2048,
    };

    try std.testing.expectEqualStrings("worktrees.git_listing_bytes: 2048 bytes; limit 1024", reach.describe(&buffer, 1));
}
