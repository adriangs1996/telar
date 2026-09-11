const PaneIdType = @import("telar-core").PaneId;
const PaneViewportChange = @This();

pane_id: PaneIdType,
offset: u32,
at_bottom: bool,
viewport_revision: u64,
