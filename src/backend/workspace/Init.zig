const core = @import("telar-core");
const Init = @This();

id: core.WorkspaceId,
path: []u8,
default_tab_id: core.TabId,
explicit_name: ?[]const u8 = null,
