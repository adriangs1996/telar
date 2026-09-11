const ClientTabLayout = @This();
const TabLocation = @import("TabLocation.zig");
const id = @import("id.zig");
const source_namespace = @import("types.zig");
location: TabLocation,
focused_pane: id.PaneId,
fullscreen: bool,
workspace_active: bool = false,
nodes: []const source_namespace.ClientLayoutNode,
