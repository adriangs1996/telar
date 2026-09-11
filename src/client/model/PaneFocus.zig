const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const PaneFocus = @This();

location: TabLocationType,
previous: PaneIdType,
focused: PaneIdType,
geometry_changed: bool,
panes_revision: u64,
