const core = @import("telar-core");
const PaneSplit = @import("PaneSplit.zig");
const ConfirmPaneSplit = @This();

requested: PaneSplit,
confirmed_pane: core.PaneId,
confirmed_location: core.TabLocation,
created: bool,
