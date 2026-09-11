const WorkspaceTabInput = @This();
const source_namespace = @import("tabs.zig");
tab_id: source_namespace.schema.TabId,
pane_count: u16,
label: []const u8,
