const std = @import("std");
const RouteMatch = @import("../RouteMatch.zig");

/// What the relay's header inflater allocates from.
gpa: std.mem.Allocator,
watched_routes: []const RouteMatch = &.{},
