const PaneFrameRecovery = @import("../state/PaneFrameRecovery.zig");
const PaneFrameCommit = @import("../state/PaneFrameCommit.zig");

pub const PaneFrameOutcome = union(enum) {
    detached,
    resync: PaneFrameRecovery,
    applied: PaneFrameCommit,
};
