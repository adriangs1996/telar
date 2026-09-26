//! The best index entries for one query, in rank order.

const core = @import("telar-core");
const PathCandidate = @import("PathCandidate.zig");
const RankedPaths = @This();

items: [core.max_path_results]PathCandidate = undefined,
len: u8 = 0,

pub fn slice(self: *const RankedPaths) []const PathCandidate {
    return self.items[0..self.len];
}
