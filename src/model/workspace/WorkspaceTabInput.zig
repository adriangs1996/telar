const core = @import("telar-core");
const WorkspaceTabInput = @This();

tab_id: core.TabId,
pane_count: u16,
label: []const u8,
foregrounds: []const core.PaneForeground = &.{},
