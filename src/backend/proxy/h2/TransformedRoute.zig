const TransformedRoute = @This();
const Route = @import("RelayRoute.zig");
const PeerSettings = @import("PeerSettings.zig");
const middleware = @import("../middleware.zig");
const std = @import("std");
route: Route,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const middleware.TransformPipeline,
io: std.Io,
transform_context: middleware.TransformContext,
