const ClientLayoutUpdate = @This();
const TabLocation = @import("TabLocation.zig");
const ClientTabLayout = @import("ClientTabLayout.zig");
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
active_tab: TabLocation,
tabs: []const ClientTabLayout,
