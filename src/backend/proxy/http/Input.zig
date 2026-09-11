const HeadType = @import("Head.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContextType = @import("../TransformContext.zig");
const Input = @This();

original: []const u8,
original_head: HeadType,
is_response: bool,
response_to_head: bool,
pipeline: *const TransformPipelineType,
io: std.Io,
context: TransformContextType,
output: []u8,
