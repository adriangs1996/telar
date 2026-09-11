const PaneInputEffect = @import("PaneInputEffect.zig");
const PaneViewportEffectsType = @import("../panes/PaneViewportEffects.zig");
const PaneInputEffects = @This();

context: *anyopaque,
send: *const fn (*anyopaque, PaneInputEffect) anyerror!void,
viewport: PaneViewportEffectsType,
