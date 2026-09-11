const pane_mouse = @import("pane_mouse.zig");
const Effects = @This();

context: *anyopaque,
apply: *const fn (*anyopaque, pane_mouse.Effect) anyerror!void,
