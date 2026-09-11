const PaneIdType = @import("telar-core").PaneId;
const PaneGraphicsFallbackCommitType = @import("../../model/PaneGraphicsFallbackCommit.zig");
const Applied = @This();

pane_id: PaneIdType,
fallback: ?PaneGraphicsFallbackCommitType,
