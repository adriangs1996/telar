//! One consumer turn. A slow handler finishes, then yields to the host.
const std = @import("std");
const Budget = @This();

pub const max_messages = 32;
pub const max_duration_ns = std.time.ns_per_ms;

remaining: usize,
started_ns: i96,
processed: usize = 0,

/// Captures a finite boundary; messages born during the turn wait for the next.
/// Example: `var budget = DrainBudget.begin(io, pending);`
pub fn begin(io: std.Io, pending: usize) Budget {
    return .{ .remaining = @min(pending, max_messages), .started_ns = std.Io.Clock.awake.now(io).toNanoseconds() };
}

/// Permits one indivisible handler, including one after an expired deadline.
/// Example: `if (!budget.take(io)) break;`
pub fn take(self: *Budget, io: std.Io) bool {
    if (self.remaining == 0 or (self.processed != 0 and std.Io.Clock.awake.now(io).toNanoseconds() - self.started_ns >= max_duration_ns)) {
        return false;
    }

    self.remaining -= 1;
    self.processed += 1;
    return true;
}
