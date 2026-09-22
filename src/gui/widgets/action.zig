const core = @import("telar-core");
const client = @import("telar-client");

pub const Action = union(enum) {
    intent: client.Intent,
    resize_sidebar,
    pane_content: core.PaneId,
};
