const types = @import("types.zig");
const RectType = @import("telar-core").Rect;
const PaneFocusRequest = @This();

target: types.PaneFocusTarget,
area: RectType,
