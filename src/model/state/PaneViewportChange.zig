const core = @import("telar-core");
const PaneViewportChange = @This();

pane_id: core.PaneId,
offset: u32,
at_bottom: bool,
viewport_revision: u64,
