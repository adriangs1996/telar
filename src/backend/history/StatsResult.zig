const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const StatsTop = @import("StatsTop.zig");
const std = @import("std");
/// Owned aggregate result for one stats query.
const StatsResult = @This();

request_id: core.RequestId,
origin: QueryOrigin,
total: u64,
unique: u64,
top: []StatsTop,
gpa: std.mem.Allocator,

pub fn deinit(self: *StatsResult) void {
    for (self.top) |entry| self.gpa.free(entry.command);
    self.gpa.free(self.top);
    self.gpa.destroy(self);
}
