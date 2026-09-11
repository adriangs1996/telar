const TabLocation = @import("TabLocation.zig");
const id = @import("id.zig");
const types = @import("types.zig");
const ClientTabLayout = @This();

location: TabLocation,
focused_pane: id.PaneId,
fullscreen: bool,
workspace_active: bool = false,
nodes: []const types.ClientLayoutNode,
