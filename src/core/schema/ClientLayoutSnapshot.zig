const TabLocation = @import("TabLocation.zig");
const ClientTabLayout = @import("ClientTabLayout.zig");
const ClientLayoutSnapshot = @This();

restored: bool,
sidebar_visible: bool = true,
sidebar_width: u16 = 0,
workspace_list_collapsed: bool = false,
active_tab: ?TabLocation = null,
tabs: []const ClientTabLayout = &.{},
