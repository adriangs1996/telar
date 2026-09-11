const RenameTab = @This();
const source_namespace = @import("tab.zig");
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
label: []const u8,
