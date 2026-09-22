const core = @import("telar-core");
const Applied = @import("../application/panes/Applied.zig");

pub const PaneGraphicsOutcome = union(enum) {
    unchanged,
    applied: Applied,
    resync_requested: core.PaneId,
    shared_disabled: core.PaneId,
};
