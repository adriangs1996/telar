//! Limits a configuration generation reached where no client could report
//! them: while it loaded, in a reload worker, or inside a callback that
//! knows only the generation. `limit_reached.reportGeneration` reports and
//! clears them on the client's loop. One row per limit name, keeping the
//! largest amount asked for.
const core = @import("telar-core");
const std = @import("std");
const UnreportedReaches = @This();

/// Distinct limits one generation holds until the client reports them;
/// past this the extra reaches are counted in `dropped`.
pub const capacity = 16;

// SAFETY: add writes each reach before increasing count; lookup and slice read only that initialized prefix.
reach: [capacity]core.LimitReach = undefined,
count: u8 = 0,
dropped: u32 = 0,

/// Keeps one reach until the client reports it.
///
/// ```zig
/// generation.unreported.add(.{ .limit = data.bar_values.picks_limit, .requested = 20 });
/// ```
pub fn add(self: *UnreportedReaches, reach: core.LimitReach) void {
    for (self.reach[0..self.count]) |*kept| {
        if (!std.mem.eql(u8, kept.limit.name, reach.limit.name)) {
            continue;
        }

        if (reach.requested) |requested| {
            kept.requested = @max(kept.requested orelse 0, requested);
        }

        return;
    }

    if (self.count == capacity) {
        self.dropped +|= 1;
        return;
    }

    self.reach[self.count] = reach;
    self.count += 1;
}

/// The reaches kept so far, one per limit name.
/// Example: `for (generation.unreported.slice()) |reach| limit_reached.report(client, reach);`
pub fn slice(self: *const UnreportedReaches) []const core.LimitReach {
    return self.reach[0..self.count];
}

/// Forgets every reach once the client reported them.
/// Example: `generation.unreported.clear();`
pub fn clear(self: *UnreportedReaches) void {
    self.count = 0;
    self.dropped = 0;
}
