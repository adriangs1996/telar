const CreatedTab = @This();
const source_namespace = @import("tabs.zig");
location: source_namespace.schema.TabLocation,
position: u16,
label: []const u8,
root_pane_id: source_namespace.schema.PaneId,
