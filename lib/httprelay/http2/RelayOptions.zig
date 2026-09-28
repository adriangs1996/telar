const std = @import("std");
const H2Route = @import("H2Route.zig");
const RouteMatch = @import("../RouteMatch.zig");
const RelayOptions = @This();

route: H2Route,
gpa: std.mem.Allocator,
watched_routes: []const RouteMatch = &.{},
