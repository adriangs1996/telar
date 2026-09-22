const core = @import("telar-core");

pub const KeyRoutingPaneTarget = union(enum) {
    current,
    lease: core.PaneId,
};
