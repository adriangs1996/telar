const CommitPaneSplit = @This();
const PaneSplit = @import("PaneSplit.zig");
const source_namespace = @import("types.zig");
split: PaneSplit,
new_pane: source_namespace.schema.PaneId,
