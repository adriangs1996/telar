const types = @import("../../agent/types.zig");
const relay = @import("relay.zig");
const SessionType = @import("../Session.zig");
const PeerSettings = @import("PeerSettings.zig");
const TransformPipelineType = @import("../TransformPipeline.zig");
const TestTranscodeSetup = @This();

dialect: types.ApiDialect,
direction: relay.Direction,
to: SessionType.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const TransformPipelineType,
