const event = @import("event.zig");
const Upstream = @This();

/// Pairs with the matching `upstream_closed`.
id: u64,
host: event.Host,
port: u16,
