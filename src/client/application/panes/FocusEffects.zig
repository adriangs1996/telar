const FocusEffects = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("focus_pane.zig");
context: *anyopaque,
deliver: *const fn (*anyopaque, client_model.PaneFocus, source_namespace.ui.Rect) anyerror!void,
