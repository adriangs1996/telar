const Outcome = @This();
const source_namespace = @import("key_routing.zig");
owner: source_namespace.Owner,
delivered: bool = false,
lease_overflow: bool = false,
