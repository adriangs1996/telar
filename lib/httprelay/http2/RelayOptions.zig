const H2Route = @import("H2Route.zig");
const RouteMatch = @import("../RouteMatch.zig");
const Transformation = @import("Transformation.zig");
const RelayOptions = @This();

route: H2Route,
watched_routes: []const RouteMatch = &.{},
transformation: ?Transformation = null,
