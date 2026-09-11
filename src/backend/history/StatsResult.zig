/// Owned aggregate result for one stats query.
const StatsResult = @This();
const source_namespace = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
const StatsTop = @import("StatsTop.zig");
const std = @import("std");
request_id: source_namespace.schema.RequestId,
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
