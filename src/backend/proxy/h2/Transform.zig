const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContextType = @import("../TransformContext.zig");
const Transform = @This();

pipeline: *const TransformPipelineType,
io: std.Io,
context: TransformContextType,
