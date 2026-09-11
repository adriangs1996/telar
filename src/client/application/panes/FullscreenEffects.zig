const PaneGeometryChangeType = @import("../../model/PaneGeometryChange.zig");
const FullscreenEffects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, PaneGeometryChangeType) anyerror!void,
