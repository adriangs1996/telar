const relay = @import("relay.zig");
const SessionType = @import("../Session.zig");
const PeerSettings = @import("PeerSettings.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const std = @import("std");
const TransformContextType = @import("../TransformContext.zig");
/// Replaces one HPACK context with another while leaving stream IDs, DATA,
/// SETTINGS, and flow control end to end. A direction owns its inflater and
/// deflater; the reverse direction only publishes the peer SETTINGS that bound
/// its output encoding.
const TranscodeConfiguration = @This();

direction: relay.Direction,
to: SessionType.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const TransformPipelineType,
io: std.Io,
transform_context: TransformContextType,
