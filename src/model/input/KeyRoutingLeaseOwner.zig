const core = @import("telar-core");

pub const KeyRoutingLeaseOwner = union(enum) {
    ignored,
    attachment_modal,
    name_prompt,
    copy_mode,
    pane: core.PaneId,
};
