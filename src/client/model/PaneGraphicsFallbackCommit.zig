const PaneIdType = @import("telar-core").PaneId;
const PaneGraphicsFallbackCommit = @This();

pane_id: PaneIdType,
visible: bool,
pane_graphics_revision: u64,
