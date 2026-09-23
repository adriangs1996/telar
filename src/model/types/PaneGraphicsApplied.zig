const core = @import("telar-core");
const PaneGraphicsFallbackCommit = @import("../state/PaneGraphicsFallbackCommit.zig");
const PaneGraphicsApplied = @This();

pane_id: core.PaneId,
fallback: ?PaneGraphicsFallbackCommit,
