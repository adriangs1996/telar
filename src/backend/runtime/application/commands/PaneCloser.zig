/// Infallible runtime effect that starts closing every pane owned by a tab.
const PaneCloser = @This();
const source_namespace = @import("close_tab.zig");
context: *anyopaque,
close_all: *const fn (*anyopaque, source_namespace.schema.TabLocation) void,
