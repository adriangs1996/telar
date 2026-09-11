const Effects = @This();
const source_namespace = @import("pane_attachment_requests.zig");
const PaneAttachmentRequest = @import("PaneAttachmentRequest.zig");
context: *anyopaque,
attachment_pending: *const fn (*anyopaque, source_namespace.schema.PaneId) bool,
request_attachment: *const fn (*anyopaque, PaneAttachmentRequest) anyerror!void,
