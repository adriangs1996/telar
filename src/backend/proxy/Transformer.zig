const Transformation = @import("Transformation.zig");
const middleware = @import("middleware.zig");
const Transformer = @This();

context: *anyopaque,
transform: *const fn (*anyopaque, Transformation) middleware.TransformStatus,
