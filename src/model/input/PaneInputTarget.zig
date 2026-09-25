const core = @import("telar-core");
const PanePasteSession = @import("../state/PanePasteSession.zig");

pub const PaneInputTarget = union(enum) {
    focused,
    pane: core.PaneId,
    key_lease: core.PaneId,
    pointer_lease: core.PaneId,
    paste_session: PanePasteSession,
};
