const PendingAttachments = @This();
const source_namespace = @import("tab_attachment_retirement.zig");
context: *anyopaque,
pending: *const fn (*anyopaque, source_namespace.schema.PaneId) bool,
