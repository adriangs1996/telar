const data = @import("../model.zig");
const core = @import("telar-core");
const CommitPaneSplit = @This();

split: data.PaneSplit,
new_pane: core.PaneId,
