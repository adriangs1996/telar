const core = @import("telar-core");
const data = @import("../model.zig");
const CopyModeProjection = @This();

pane_id: core.PaneId,
view: data.CopyModeView,
