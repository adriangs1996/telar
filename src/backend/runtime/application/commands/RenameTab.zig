const RenameTab = @This();
const source_namespace = @import("rename_tab.zig");
location: source_namespace.schema.TabLocation,
/// Borrowed only for the synchronous `execute` call.
label: []const u8,
