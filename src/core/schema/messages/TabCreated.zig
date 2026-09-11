const TabCreated = @This();
const source_namespace = @import("tab.zig");
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
position: u16,
label: []const u8,
root_pane_id: source_namespace.PaneId,
