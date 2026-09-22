const core = @import("telar-core");
const PaneGraphicsFallbackCommitType = @import("../../state/PaneGraphicsFallbackCommit.zig");
const Applied = @This();

pane_id: core.PaneId,
fallback: ?PaneGraphicsFallbackCommitType,
