const core = @import("telar-core");
const types = @import("types.zig");
const PaneViewportCommand = @This();

pane_id: core.PaneId,
target: types.PaneViewportTarget,
