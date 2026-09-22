const core = @import("telar-core");
const Restore = @This();

id: core.WorkspaceId,
path: []const u8,
explicit_name: ?[]const u8,
first_tab_id: core.TabId,
first_tab_label: []const u8,
