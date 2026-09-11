const Route = @import("Route.zig");
const Effects = @This();

context: *anyopaque,
route: *const fn (*anyopaque, Route) anyerror!void,
