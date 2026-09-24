const localca = @import("localca");
const Session = localca.Session;
const RouteMatch = @import("../RouteMatch.zig");
const MessageRoute = @This();

from: Session.Side,
to: Session.Side,
is_response: bool,
response_to_head: bool,
/// Request routes the caller watches; the parsed head reports a match.
watched_routes: []const RouteMatch = &.{},
