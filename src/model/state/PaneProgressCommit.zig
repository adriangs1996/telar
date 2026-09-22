const core = @import("telar-core");
const PaneProgressCommit = @This();

pane_id: core.PaneId,
active: bool,
pane_progress_revision: u64,
