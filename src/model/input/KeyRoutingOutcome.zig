const key_routing = @import("key_routing.zig");
const Outcome = @This();

owner: key_routing.Owner,
delivered: bool = false,
lease_overflow: bool = false,
