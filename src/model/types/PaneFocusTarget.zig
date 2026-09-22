const core = @import("telar-core");
const layout_mod = @import("../workspace/layout_support.zig");

pub const PaneFocusTarget = union(enum) {
    pane_id: core.PaneId,
    direction: layout_mod.Direction,
};
