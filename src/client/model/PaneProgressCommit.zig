const PaneIdType = @import("telar-core").PaneId;
const PaneProgressCommit = @This();

pane_id: PaneIdType,
active: bool,
pane_progress_revision: u64,
