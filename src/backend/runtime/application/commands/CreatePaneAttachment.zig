const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const PaneAttachment = @This();

context: *anyopaque,
attach: *const fn (*anyopaque, PaneLaunchedType) anyerror!void,
