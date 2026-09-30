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

pub fn slice(self: *const UnreportedReaches) []const core.LimitReach {
    return self.reach[0..self.count];
}

pub fn clear(self: *UnreportedReaches) void {
    self.count = 0;
    self.dropped = 0;
}

test "a reach per limit keeps the largest amount and a full list counts the rest" {
    var reaches: UnreportedReaches = .{};
    const limit = core.Limit.declare("picks.max_picks", "picks", 16);
    reaches.add(.{
        .limit = limit,
        .requested = 20,
    });
    reaches.add(.{
        .limit = limit,
        .requested = 18,
    });
    try std.testing.expectEqual(@as(u8, 1), reaches.count);
    try std.testing.expectEqual(@as(?u64, 20), reaches.slice()[0].requested);

    for (0..capacity) |_| {
        reaches.add(.{
            .limit = core.Limit.declare("panels.max_panels", "panels", 16),
        });
    }

    try std.testing.expectEqual(@as(u8, 2), reaches.count);
    reaches.count = capacity;
    reaches.add(.{
        .limit = core.Limit.declare("bars.max_bar_nodes", "components", 64),
    });
    try std.testing.expectEqual(@as(u32, 1), reaches.dropped);
}
