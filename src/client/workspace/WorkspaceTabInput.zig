const TabIdType = @import("telar-core").TabId;
const WorkspaceTabInput = @This();

tab_id: TabIdType,
pane_count: u16,
label: []const u8,
