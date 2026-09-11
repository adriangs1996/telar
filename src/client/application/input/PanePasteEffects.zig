const pane_paste = @import("pane_paste.zig");
const Effects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, pane_paste.Delivery) anyerror!bool,
