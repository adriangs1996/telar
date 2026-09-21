const PaneSplitType = @import("../../model/PaneSplit.zig");
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const ConfirmPaneSplit = @This();

requested: PaneSplitType,
confirmed_pane: PaneIdType,
confirmed_location: TabLocationType,
created: bool,
