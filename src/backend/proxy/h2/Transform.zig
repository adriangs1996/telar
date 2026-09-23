const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContext = @import("../TransformContext.zig");
const Transform = @This();

pipeline: *const TransformPipeline,
io: std.Io,
context: TransformContext,
