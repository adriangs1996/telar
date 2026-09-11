const Transform = @This();
const middleware = @import("../middleware.zig");
const std = @import("std");
pipeline: *const middleware.TransformPipeline,
io: std.Io,
context: middleware.TransformContext,
