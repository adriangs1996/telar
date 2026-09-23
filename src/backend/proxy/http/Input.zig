const Head = @import("Head.zig");
const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContext = @import("../TransformContext.zig");
const Input = @This();

original: []const u8,
original_head: Head,
is_response: bool,
response_to_head: bool,
pipeline: *const TransformPipeline,
io: std.Io,
context: TransformContext,
output: []u8,
