const Settings = @This();
const relay = @import("relay.zig");
child: relay.PeerSettings = .{},
origin: relay.PeerSettings = .{},
