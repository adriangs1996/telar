const TestDecisionInput = @This();
const middleware = @import("../middleware.zig");
original: []const u8,
is_response: bool,
pipeline: *const middleware.TransformPipeline,
output: []u8,
