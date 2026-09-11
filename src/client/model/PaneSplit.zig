const PaneSplit = @This();
const source_namespace = @import("types.zig");
target_pane: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
axis: source_namespace.layout_mod.Axis,
area: source_namespace.ui.Rect,
