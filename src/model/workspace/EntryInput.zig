const core = @import("telar-core");

workspace: core.WorkspaceId,
name: []const u8,
path: []const u8,
tab_count: u16,
branch: []const u8 = "",
dirty: bool = false,
