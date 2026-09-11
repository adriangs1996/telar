const AttachedPaneCloser = @This();
const source_namespace = @import("close_pane.zig");
context: *anyopaque,
request_close: *const fn (*anyopaque, source_namespace.schema.PaneId) ?bool,
