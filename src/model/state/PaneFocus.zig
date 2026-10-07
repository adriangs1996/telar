const core = @import("telar-core");

location: core.TabLocation,
previous: core.PaneId,
focused: core.PaneId,
geometry_changed: bool,
panes_revision: u64,
