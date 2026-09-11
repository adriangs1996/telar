const TabRenameIntent = @This();
const source_namespace = @import("rename_tab.zig");
location: source_namespace.schema.TabLocation,
/// Borrowed only for the synchronous send callback.
label: []const u8,
