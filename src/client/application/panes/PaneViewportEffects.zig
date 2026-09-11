const PaneViewportEffects = @This();
const client_model = @import("../../root.zig").model;
context: *anyopaque,
sync: *const fn (*anyopaque, client_model.PaneViewportChange) anyerror!void,
