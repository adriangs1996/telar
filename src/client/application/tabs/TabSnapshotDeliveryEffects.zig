const Effects = @This();
const source_namespace = @import("tab_snapshot_delivery.zig");
context: *anyopaque,
ignore_pane_requests: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
clear_pane_graphics: *const fn (*anyopaque, source_namespace.schema.PaneId) void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
attachment_pending: *const fn (*anyopaque, source_namespace.schema.PaneId) bool,
request_attachment: *const fn (*anyopaque, source_namespace.PaneAttachmentRequest) anyerror!void,
