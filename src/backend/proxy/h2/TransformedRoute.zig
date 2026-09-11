const RelayRoute = @import("RelayRoute.zig");
const PeerSettings = @import("PeerSettings.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContextType = @import("../TransformContext.zig");
const TransformedRoute = @This();

route: RelayRoute,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const TransformPipelineType,
io: std.Io,
transform_context: TransformContextType,
