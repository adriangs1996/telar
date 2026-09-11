const Effects = @This();
const Route = @import("Route.zig");
context: *anyopaque,
route: *const fn (*anyopaque, Route) anyerror!void,
