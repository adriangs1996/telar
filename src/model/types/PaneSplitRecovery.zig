const core = @import("telar-core");

pub const PaneSplitRecovery = union(enum) {
    resize: core.PaneResize,
    not_required,
    stale,
};
