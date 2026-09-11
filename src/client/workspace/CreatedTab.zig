const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const CreatedTab = @This();

location: TabLocationType,
position: u16,
label: []const u8,
root_pane_id: PaneIdType,
