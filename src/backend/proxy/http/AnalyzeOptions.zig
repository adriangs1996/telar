const RouteMatch = @import("../RouteMatch.zig");
const AnalyzeOptions = @This();

is_response: bool,
response_to_head: bool,
/// Request routes the caller watches; `Head.watched` reports a match.
watched_routes: []const RouteMatch = &.{},
