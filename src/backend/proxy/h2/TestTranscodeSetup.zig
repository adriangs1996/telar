const types = @import("../../agent/types.zig");
const relay = @import("relay.zig");
const Session = @import("../Session.zig");
const PeerSettings = @import("PeerSettings.zig");
const TransformPipeline = @import("../TransformPipeline.zig");
const TestTranscodeSetup = @This();

dialect: types.ApiDialect,
direction: relay.Direction,
to: Session.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const TransformPipeline,
