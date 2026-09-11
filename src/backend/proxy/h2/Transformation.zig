const Transformation = @This();
const source_namespace = @import("root.zig");
const middleware = @import("../middleware.zig");
const std = @import("std");
source_settings: *source_namespace.PeerSettings,
target_settings: *source_namespace.PeerSettings,
pipeline: *const middleware.TransformPipeline,
io: std.Io,
context: middleware.TransformContext,
