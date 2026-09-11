const TransformPipelineType = @import("../TransformPipeline.zig");
const TestDecisionInput = @This();

original: []const u8,
is_response: bool,
pipeline: *const TransformPipelineType,
output: []u8,
