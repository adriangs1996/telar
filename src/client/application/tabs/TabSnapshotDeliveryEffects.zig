const PaneIdType = @import("telar-core").PaneId;
const PaneAttachmentRequestType = @import("../panes/PaneAttachmentRequest.zig");
const Effects = @This();

context: *anyopaque,
ignore_pane_requests: *const fn (*anyopaque, PaneIdType) void,
clear_pane_graphics: *const fn (*anyopaque, PaneIdType) void,
synchronize_active_resources: *const fn (*anyopaque) anyerror!void,
attachment_pending: *const fn (*anyopaque, PaneIdType) bool,
request_attachment: *const fn (*anyopaque, PaneAttachmentRequestType) anyerror!void,
