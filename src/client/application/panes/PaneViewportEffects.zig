const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const PaneViewportEffects = @This();

context: *anyopaque,
sync: *const fn (*anyopaque, PaneViewportChangeType) anyerror!void,
