const TransformPipeline = @import("../TransformPipeline.zig");
const TestDecisionInput = @This();

original: []const u8,
is_response: bool,
pipeline: *const TransformPipeline,
output: []u8,
