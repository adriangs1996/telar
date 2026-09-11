const QueryResult = @This();
const source_namespace = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
const Entry = @import("Entry.zig");
const std = @import("std");
request_id: source_namespace.schema.RequestId,
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
