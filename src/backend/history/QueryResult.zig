const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const Entry = @import("Entry.zig");
const std = @import("std");
const QueryResult = @This();

request_id: RequestIdType,
origin: QueryOrigin,
entries: []Entry,
gpa: std.mem.Allocator,
snapshot_id: u64 = 0,
has_more: bool = false,

pub fn deinit(result: *QueryResult) void {
    for (result.entries) |*entry| entry.deinit(result.gpa);
    result.gpa.free(result.entries);
    result.gpa.destroy(result);
}
