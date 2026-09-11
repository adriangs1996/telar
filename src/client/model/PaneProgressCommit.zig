const PaneProgressCommit = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
active: bool,
pane_progress_revision: u64,
