const core = @import("telar-core");
const PaneGeometryChange = @This();

location: core.TabLocation,
focused: core.PaneId,
panes_revision: u64,
area: core.Rect,
fullscreen: bool,
