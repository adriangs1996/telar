const RelayRoute = @import("RelayRoute.zig");
const PeerSettings = @import("PeerSettings.zig");
const TransformPipeline = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContext = @import("../TransformContext.zig");
const TransformedRoute = @This();

route: RelayRoute,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const TransformPipeline,
io: std.Io,
transform_context: TransformContext,
