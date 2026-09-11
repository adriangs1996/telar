const RequestIdType = @import("telar-core").RequestId;
const QueryOrigin = @import("QueryOrigin.zig");
const std = @import("std");
/// Owned captured-output read result.
const OutputResult = @This();

request_id: RequestIdType,
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
