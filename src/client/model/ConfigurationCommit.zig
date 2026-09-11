const ConfigurationCommit = @This();
const SidebarLayout = @import("SidebarLayout.zig");
generation: u64,
configuration_revision: u64,
sidebar: ?SidebarLayout,
pane_gaps_changed: bool,
panes_revision: u64,
bars_changed: bool = false,
bars_revision: u64 = 0,
