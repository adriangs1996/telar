const RouteMatch = @import("../RouteMatch.zig");
const RelayConfiguration = @This();

watched_routes: []const RouteMatch = &.{},
