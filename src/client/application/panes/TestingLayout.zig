const TestingLayout = @This();
const source_namespace = @import("pane_geometry_delivery.zig");
location: source_namespace.schema.TabLocation,
first: source_namespace.schema.PaneId,
second: source_namespace.schema.PaneId,
area: source_namespace.ui.Rect,
