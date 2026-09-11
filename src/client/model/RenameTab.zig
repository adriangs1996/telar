const RenameTab = @This();
const source_namespace = @import("types.zig");
location: source_namespace.schema.TabLocation,
/// Borrowed only for the synchronous transition.
label: []const u8,
