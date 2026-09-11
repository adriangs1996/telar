const EventPublisher = @This();
const pane_mod = @import("../../../pane/root.zig");
context: *anyopaque,
publish: *const fn (*anyopaque, pane_mod.PaneLaunched) void,
