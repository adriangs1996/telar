const PeerSettingsType = @import("PeerSettings.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContextType = @import("../TransformContext.zig");
const Transformation = @This();

source_settings: *PeerSettingsType,
target_settings: *PeerSettingsType,
pipeline: *const TransformPipelineType,
io: std.Io,
context: TransformContextType,
