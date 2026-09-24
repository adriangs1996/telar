const RelayRoute = @import("RelayRoute.zig");
const h2frames = @import("h2frames");
const PeerSettings = h2frames.PeerSettings;
const Rewrite = @import("../Rewrite.zig");
const TransformedRoute = @This();

route: RelayRoute,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
rewrites: []const Rewrite,
