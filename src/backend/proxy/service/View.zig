const TransformPipeline = @import("../TransformPipeline.zig");
const View = @This();

transforms: *const TransformPipeline,
has_custom_transformers: bool,
