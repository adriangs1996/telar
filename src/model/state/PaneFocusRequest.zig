const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const layout_mod = @import("../workspace/layout_support.zig");
const PaneFocusRequest = @This();

target: PaneFocusTarget,
area: cellgrid.Rect,

const PaneFocusTarget = union(enum) {
    pane_id: core.PaneId,
    direction: layout_mod.Direction,
};
