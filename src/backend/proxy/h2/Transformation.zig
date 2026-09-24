const h2frames = @import("h2frames");
const PeerSettings = h2frames.PeerSettings;
const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContext = @import("../TransformContext.zig");
const Transformation = @This();

source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const TransformPipeline,
io: std.Io,
context: TransformContext,
