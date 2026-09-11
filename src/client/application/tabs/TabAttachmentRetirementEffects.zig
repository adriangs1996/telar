const Effects = @This();
const source_namespace = @import("tab_attachment_retirement.zig");
context: *anyopaque,
attachment_pending: *const fn (*anyopaque, source_namespace.schema.PaneId) bool,
detach_pane: *const fn (*anyopaque, source_namespace.schema.PaneId) anyerror!void,
retire_attachment: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
hide_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) anyerror!void,
