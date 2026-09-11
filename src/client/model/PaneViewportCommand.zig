const PaneIdType = @import("telar-core").PaneId;
const types = @import("types.zig");
const PaneViewportCommand = @This();

pane_id: PaneIdType,
target: types.PaneViewportTarget,
