const EntryInput = @This();
const source_namespace = @import("workspace_list.zig");
workspace: source_namespace.schema.WorkspaceId,
name: []const u8,
path: []const u8,
tab_count: u16,
branch: []const u8 = "",
dirty: bool = false,
