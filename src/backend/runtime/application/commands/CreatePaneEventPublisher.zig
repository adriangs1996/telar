const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const EventPublisher = @This();

context: *anyopaque,
publish: *const fn (*anyopaque, PaneLaunchedType) void,
