const Source = @This();
const source_namespace = @import("tab_snapshot.zig");
context: *anyopaque,
contains_tab: *const fn (*anyopaque, source_namespace.schema.TabLocation) bool,
running_panes: *const fn (*anyopaque, source_namespace.schema.TabLocation) u16,
