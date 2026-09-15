const TabIdType = @import("telar-core").TabId;
const PaneForeground = @import("telar-core").PaneForeground;
const WorkspaceTabInput = @This();

tab_id: TabIdType,
pane_count: u16,
label: []const u8,
foregrounds: []const PaneForeground = &.{},
