const OpenedPane = @This();
const source_namespace = @import("pane_open_delivery.zig");
pane_id: source_namespace.schema.PaneId,
location: source_namespace.schema.TabLocation,
created: bool,
