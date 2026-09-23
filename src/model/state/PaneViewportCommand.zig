const core = @import("telar-core");
const PaneViewportTarget = @import("../types/PaneViewportTarget.zig").PaneViewportTarget;
const PaneViewportCommand = @This();

pane_id: core.PaneId,
target: PaneViewportTarget,
