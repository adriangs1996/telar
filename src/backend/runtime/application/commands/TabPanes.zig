const TabPanes = @This();
const source_namespace = @import("create_pane.zig");
context: *anyopaque,
has_running: *const fn (*anyopaque, source_namespace.schema.TabLocation) bool,
