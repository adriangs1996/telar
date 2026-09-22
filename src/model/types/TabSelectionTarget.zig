const core = @import("telar-core");

pub const TabSelectionTarget = union(enum) {
    tab_id: core.TabId,
    offset: isize,
    position: usize,
};
