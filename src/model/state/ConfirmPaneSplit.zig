const core = @import("telar-core");
const PaneSplitType = @import("PaneSplit.zig");
const ConfirmPaneSplit = @This();

requested: PaneSplitType,
confirmed_pane: core.PaneId,
confirmed_location: core.TabLocation,
created: bool,
