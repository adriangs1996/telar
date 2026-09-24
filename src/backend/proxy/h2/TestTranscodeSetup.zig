const types = @import("../../agent/types.zig");
const relay = @import("relay.zig");
const localca = @import("localca");
const Session = localca.Session;
const h2frames = @import("h2frames");
const PeerSettings = h2frames.PeerSettings;
const Rewrite = @import("../Rewrite.zig");
const TestTranscodeSetup = @This();

dialect: types.ApiDialect,
direction: relay.Direction,
to: Session.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
rewrites: []const Rewrite,
