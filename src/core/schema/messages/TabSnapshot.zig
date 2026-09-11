const TabSnapshot = @This();
const source_namespace = @import("tab.zig");
request_id: source_namespace.RequestId,
location: source_namespace.TabLocation,
panes: []const source_namespace.PaneDescriptor,
