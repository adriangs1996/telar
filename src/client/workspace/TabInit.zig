const TabInit = @This();
const source_namespace = @import("tabs.zig");
location: source_namespace.schema.TabLocation,
label: []const u8,
pane_gaps: bool,
