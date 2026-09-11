/// Owned captured-output read result.
const OutputResult = @This();
const source_namespace = @import("model.zig");
const QueryOrigin = @import("QueryOrigin.zig");
const std = @import("std");
request_id: source_namespace.schema.RequestId,
origin: QueryOrigin,
id: u64,
truncated: bool,
observed_bytes: u64,
content: []u8,
gpa: std.mem.Allocator,

pub fn deinit(result: *OutputResult) void {
    result.gpa.free(result.content);
    result.gpa.destroy(result);
}
