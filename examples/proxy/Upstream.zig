const Upstream = @This();
const source_namespace = @import("event.zig");
/// Pairs with the matching `upstream_closed`.
id: u64,
host: source_namespace.Host,
port: u16,
