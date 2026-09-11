const Split = @This();
const source_namespace = @import("requests.zig");
const layout = @import("../workspace/root.zig").layout;
target_pane: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
axis: layout.Axis,
area: source_namespace.ui.Rect,
