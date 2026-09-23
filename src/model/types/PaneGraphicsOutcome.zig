const core = @import("telar-core");
const PaneGraphicsApplied = @import("PaneGraphicsApplied.zig");

pub const PaneGraphicsOutcome = union(enum) {
    unchanged,
    applied: PaneGraphicsApplied,
    resync_requested: core.PaneId,
    shared_disabled: core.PaneId,
};
