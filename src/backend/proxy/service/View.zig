const TransformPipelineType = @import("../TransformPipeline.zig");
const View = @This();

transforms: *const TransformPipelineType,
has_custom_transformers: bool,
