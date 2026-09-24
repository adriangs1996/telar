const cellgrid = @import("cellgrid");
const PaneFocusTarget = @import("../types/PaneFocusTarget.zig").PaneFocusTarget;
const PaneFocusRequest = @This();

target: PaneFocusTarget,
area: cellgrid.Rect,
