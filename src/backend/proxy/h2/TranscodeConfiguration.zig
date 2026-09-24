const relay = @import("relay.zig");
const localca = @import("localca");
const Session = localca.Session;
const h2frames = @import("h2frames");
const PeerSettings = h2frames.PeerSettings;
const Rewrite = @import("../Rewrite.zig");
/// Replaces one HPACK context with another while leaving stream IDs, DATA,
/// SETTINGS, and flow control end to end. A direction owns its inflater and
/// deflater; the reverse direction only publishes the peer SETTINGS that bound
/// its output encoding.
const TranscodeConfiguration = @This();

direction: relay.Direction,
to: Session.Side,
source_settings: *PeerSettings,
target_settings: *PeerSettings,
rewrites: []const Rewrite,
