const KeyRoutingOutcome = @import("KeyRoutingOutcome.zig");
const key_routing = @import("key_routing.zig");
const Routed = @This();

outcome: KeyRoutingOutcome,
lease_owner: key_routing.LeaseOwner,
