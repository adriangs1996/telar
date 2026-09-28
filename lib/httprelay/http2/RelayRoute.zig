const std = @import("std");
const localca = @import("localca");
const Session = localca.Session;
const relay = @import("relay.zig");
const RouteMatch = @import("../RouteMatch.zig");
const Route = @This();

from: Session.Side,
to: Session.Side,
direction: relay.Direction,
/// What the header inflater allocates from.
gpa: std.mem.Allocator,
watched_routes: []const RouteMatch = &.{},
