const localca = @import("localca");
const Session = localca.Session;
const relay = @import("relay.zig");
const RouteMatch = @import("../RouteMatch.zig");
const Route = @This();

from: Session.Side,
to: Session.Side,
direction: relay.Direction,
watched_routes: []const RouteMatch = &.{},
