const PaneSplit = @This();
const source_namespace = @import("multiplexer.zig");
const layout_mod = @import("layout_support.zig");
existing_pane: source_namespace.schema.PaneId,
new_pane: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
axis: layout_mod.Axis,
area: source_namespace.ui.Rect,
