const H2Route = @import("H2Route.zig");
const RouteMatch = @import("../RouteMatch.zig");
const RelayOptions = @This();

route: H2Route,
watched_routes: []const RouteMatch = &.{},
