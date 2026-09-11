const PaneInputEffects = @This();
const PaneInputEffect = @import("PaneInputEffect.zig");
const set_pane_viewport = @import("../panes/root.zig").set_pane_viewport;
context: *anyopaque,
send: *const fn (*anyopaque, PaneInputEffect) anyerror!void,
viewport: set_pane_viewport.PaneViewportEffects,
