const pane_mouse = @import("pane_mouse.zig");
const Resolved = @import("Resolved.zig");
const Plans = @This();

context: *anyopaque,
resolve: *const fn (*anyopaque, pane_mouse.Command) ?Resolved,
