const core = @import("telar-core");
const QueryOrigin = @import("QueryOrigin.zig");
const Entry = @import("Entry.zig");
const std = @import("std");
const QueryResult = @This();

request_id: core.RequestId,
origin: QueryOrigin,
entries: []Entry,
gpa: std.mem.Allocator,
snapshot_id: u64 = 0,
has_more: bool = false,

pub fn deinit(self: *QueryResult) void {
    for (self.entries) |*entry| entry.deinit(self.gpa);
    self.gpa.free(self.entries);
    self.gpa.destroy(self);
}
