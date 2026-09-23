const core = @import("telar-core");
const PaneGraphicsFallbackCommit = @import("../../state/PaneGraphicsFallbackCommit.zig");
const Applied = @This();

pane_id: core.PaneId,
fallback: ?PaneGraphicsFallbackCommit,
