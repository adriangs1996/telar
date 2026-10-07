const core = @import("telar-core");
const PaneSplit = @import("PaneSplit.zig");

requested: PaneSplit,
confirmed_pane: core.PaneId,
confirmed_location: core.TabLocation,
created: bool,
