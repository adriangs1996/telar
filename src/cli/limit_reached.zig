//! Limit reached, command-line side: a command that stops at a limit keeps
//! what fits, prints the notice text on standard error and, when it holds a
//! runtime session, reports the reach so the windows show it and
//! `telar diagnostics limits` lists it. See `docs/flows/limit-reached.md`.
const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");

/// Prints the notice for `reach` and reports it through `session` when
/// there is one. Never fails: a report that cannot be sent still leaves
/// the line on standard error.
///
/// ```zig
/// limit_reached.report(&session, .{ .limit = hooks_input_limit, .requested = len });
/// ```
pub fn report(session: ?*Session, reach: core.LimitReach) void {
    var buffer: [core.LimitReach.max_description_bytes]u8 = undefined;
    std.debug.print("telar: limit reached: {s}\n", .{reach.describe(&buffer, 1)});

    const connected = session orelse return;
    connected.reportLimit(reach) catch {};
}
