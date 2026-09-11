const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const OpenedPane = @This();

pane_id: PaneIdType,
location: TabLocationType,
created: bool,
