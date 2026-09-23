const core = @import("telar-core");
const PaneFocusTarget = @import("../types/PaneFocusTarget.zig").PaneFocusTarget;
const PaneFocusRequest = @This();

target: PaneFocusTarget,
area: core.Rect,
