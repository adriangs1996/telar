//! Limits the window reached outside update: while it recorded native input,
//! measured a viewport or prepared and drew a frame. Update reports them to
//! the presented client before it flushes, so only update changes a model.
//! One row per limit and route; reaching it again adds a hit.
const std = @import("std");
const core = @import("telar-core");
const WindowLimit = @import("WindowLimit.zig").WindowLimit;
const CollectedReaches = @This();

/// The routes whose limit errors the window absorbs outside a client.
const AbsorbedRoute = enum { window_draw, window_input, window_update };

const Room = enum(usize) {
    limits_per_route = 2,
};

/// Every window limit, plus room for a few limits on each absorbed route
/// between two updates.
pub const capacity = std.meta.fields(WindowLimit).len + std.meta.fields(AbsorbedRoute).len * @intFromEnum(Room.limits_per_route);

// SAFETY: add writes each row below count before any reader sees it.
reach: [capacity]core.LimitReach = undefined,
hits: [capacity]u32 = @splat(0),
count: usize = 0,
/// Reaches that found no row; logged when update reports the rest.
dropped: u64 = 0,

/// Records one reach. Its limit name and route must outlive the next
/// update, as declared limits and error names do.
/// Example: `reaches.add(reach);`
pub fn add(self: *CollectedReaches, reach: core.LimitReach) void {
    for (self.reach[0..self.count], self.hits[0..self.count]) |*row, *hits| {
        if (std.mem.eql(u8, row.limit.name, reach.limit.name) and std.mem.eql(u8, row.route, reach.route)) {
            row.* = reach;
            hits.* +|= 1;
            return;
        }
    }

    if (self.count == capacity) {
        self.dropped +|= 1;
        return;
    }

    self.reach[self.count] = reach;
    self.hits[self.count] = 1;
    self.count += 1;
}

/// Example: `reaches.clear();`
pub fn clear(self: *CollectedReaches) void {
    self.count = 0;
    self.dropped = 0;
}
