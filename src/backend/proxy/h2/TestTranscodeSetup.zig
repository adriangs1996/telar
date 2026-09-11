const TestTranscodeSetup = @This();
const provider = @import("../provider/request_support.zig");
const source_namespace = @import("relay.zig");
const tls = @import("../tls.zig");
const PeerSettings = @import("PeerSettings.zig");
const middleware = @import("../middleware.zig");
dialect: provider.ApiDialect,
direction: source_namespace.Direction,
to: tls.Session.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
pipeline: *const middleware.TransformPipeline,
