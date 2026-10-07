//! A CLI command at one of telar's limits. It has no model and no window,
//! so it keeps what fit, prints the limit notice on standard error and the
//! command exits nonzero. A command that holds a runtime session also
//! reports the reach, so the windows show it and `telar diagnostics limits`
//! lists it.
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
    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    // This is a user-facing limit notice for CLI commands, which have no UI notification surface.
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
    // The local notice was already emitted; forwarding it to the runtime is best effort.
    session.reportLimit(reach) catch {};
}
