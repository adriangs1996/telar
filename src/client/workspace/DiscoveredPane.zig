const DiscoveredPane = @This();
const source_namespace = @import("multiplexer.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
area: source_namespace.ui.Rect,
