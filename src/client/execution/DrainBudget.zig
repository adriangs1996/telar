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
pub fn take(budget: *Budget, io: std.Io) bool {
    if (budget.remaining == 0 or (budget.processed != 0 and std.Io.Clock.awake.now(io).toNanoseconds() - budget.started_ns >= max_duration_ns)) {
        return false;
    }

    budget.remaining -= 1;
    budget.processed += 1;
    return true;
}
