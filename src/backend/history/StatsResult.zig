const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const StatsTop = @import("StatsTop.zig");
const std = @import("std");
/// Owned aggregate result for one stats query.
const StatsResult = @This();

request_id: RequestIdType,
origin: QueryOrigin,
total: u64,
unique: u64,
top: []StatsTop,
gpa: std.mem.Allocator,

pub fn deinit(result: *StatsResult) void {
    for (result.top) |entry| result.gpa.free(entry.command);
    result.gpa.free(result.top);
    result.gpa.destroy(result);
}
