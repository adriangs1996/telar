const Input = @This();
const head = @import("head_support.zig");
const middleware = @import("../middleware.zig");
const std = @import("std");
original: []const u8,
original_head: head.Head,
is_response: bool,
response_to_head: bool,
pipeline: *const middleware.TransformPipeline,
io: std.Io,
context: middleware.TransformContext,
output: []u8,
