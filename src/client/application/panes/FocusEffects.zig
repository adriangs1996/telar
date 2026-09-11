const PaneFocusType = @import("../../model/PaneFocus.zig");
const RectType = @import("telar-core").Rect;
const FocusEffects = @This();

context: *anyopaque,
deliver: *const fn (*anyopaque, PaneFocusType, RectType) anyerror!void,
