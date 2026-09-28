const std = @import("std");
const RouteMatch = @import("../RouteMatch.zig");
const RelayConfiguration = @This();

/// What the relay's header inflater allocates from.
gpa: std.mem.Allocator,
watched_routes: []const RouteMatch = &.{},
