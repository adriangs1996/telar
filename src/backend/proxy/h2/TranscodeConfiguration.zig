/// Replaces one HPACK context with another while leaving stream IDs, DATA,
/// SETTINGS, and flow control end to end. A direction owns its inflater and
/// deflater; the reverse direction only publishes the peer SETTINGS that bound
/// its output encoding.
const TranscodeConfiguration = @This();
const source_namespace = @import("relay.zig");
const tls = @import("../tls.zig");
const PeerSettings = @import("PeerSettings.zig");
const middleware = @import("../middleware.zig");
const std = @import("std");
direction: source_namespace.Direction,
to: tls.Session.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const middleware.TransformPipeline,
io: std.Io,
transform_context: middleware.TransformContext,
