const RouteMatch = @import("../RouteMatch.zig");

is_response: bool,
response_to_head: bool,
/// Request routes the caller watches; `Head.watched` reports a match.
watched_routes: []const RouteMatch = &.{},
