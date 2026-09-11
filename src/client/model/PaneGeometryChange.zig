const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const PaneGeometryChange = @This();

location: TabLocationType,
focused: PaneIdType,
panes_revision: u64,
area: RectType,
fullscreen: bool,
