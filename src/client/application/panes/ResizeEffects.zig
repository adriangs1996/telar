const PaneGeometryChangeType = @import("../../model/PaneGeometryChange.zig");
const ResizeEffects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, PaneGeometryChangeType) anyerror!void,
