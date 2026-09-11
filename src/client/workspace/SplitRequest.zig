const SplitRequest = @This();
const source_namespace = @import("layout_support.zig");
existing_pane: source_namespace.schema.PaneId,
new_pane: source_namespace.schema.PaneId,
axis: source_namespace.Axis,
