const Transformer = @This();
const Transformation = @import("Transformation.zig");
const source_namespace = @import("middleware.zig");
context: *anyopaque,
transform: *const fn (*anyopaque, Transformation) source_namespace.TransformStatus,
