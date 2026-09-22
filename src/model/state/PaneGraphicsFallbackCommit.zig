const core = @import("telar-core");
const PaneGraphicsFallbackCommit = @This();

pane_id: core.PaneId,
visible: bool,
pane_graphics_revision: u64,
