const RouteMatch = @import("../RouteMatch.zig");
const Transform = @import("Transform.zig");
const RelayConfiguration = @This();

watched_routes: []const RouteMatch = &.{},
transformation: ?Transform = null,
