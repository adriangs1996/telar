const PaneSplit = @import("PaneSplit.zig");
const PaneIdType = @import("telar-core").PaneId;
const CommitPaneSplit = @This();

split: PaneSplit,
new_pane: PaneIdType,
