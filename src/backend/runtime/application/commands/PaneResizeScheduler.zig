const PaneType = @import("../../../pane/Pane.zig");
const Scheduler = @This();

context: *anyopaque,
observation: *const fn (*anyopaque, *PaneType) anyerror!void,
media: *const fn (*anyopaque, *PaneType) anyerror!void,
response: *const fn (*anyopaque, *PaneType) anyerror!void,
