const View = @This();
const middleware = @import("../middleware.zig");
transforms: *const middleware.TransformPipeline,
has_custom_transformers: bool,
