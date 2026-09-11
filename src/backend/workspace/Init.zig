const WorkspaceIdType = @import("telar-core").WorkspaceId;
const TabIdType = @import("telar-core").TabId;
const Init = @This();

id: WorkspaceIdType,
path: []u8,
default_tab_id: TabIdType,
explicit_name: ?[]const u8 = null,
