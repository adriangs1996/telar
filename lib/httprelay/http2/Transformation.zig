const h2frames = @import("h2frames");
const PeerSettings = h2frames.PeerSettings;
const Rewrite = @import("../Rewrite.zig");
/// Header transcoding for one direction: the peer settings that bound its
/// output and the rewrites applied to its heads.
const Transformation = @This();

source_settings: *PeerSettings,
target_settings: *PeerSettings,
rewrites: []const Rewrite,
