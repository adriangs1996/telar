const PaneOpened = @This();
const source_namespace = @import("pane.zig");
request_id: source_namespace.RequestId,
pane_id: source_namespace.PaneId,
location: source_namespace.TabLocation,
created: bool,
