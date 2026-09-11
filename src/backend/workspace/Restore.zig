const WorkspaceIdType = @import("telar-core").WorkspaceId;
const TabIdType = @import("telar-core").TabId;
const Restore = @This();

id: WorkspaceIdType,
path: []const u8,
explicit_name: ?[]const u8,
first_tab_id: TabIdType,
first_tab_label: []const u8,
