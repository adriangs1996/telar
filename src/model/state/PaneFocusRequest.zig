const core = @import("telar-core");
const types = @import("types.zig");
const PaneFocusRequest = @This();

target: types.PaneFocusTarget,
area: core.Rect,
