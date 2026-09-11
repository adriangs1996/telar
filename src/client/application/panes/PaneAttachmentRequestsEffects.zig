const PaneIdType = @import("telar-core").PaneId;
const PaneAttachmentRequest = @import("PaneAttachmentRequest.zig");
const Effects = @This();

context: *anyopaque,
attachment_pending: *const fn (*anyopaque, PaneIdType) bool,
request_attachment: *const fn (*anyopaque, PaneAttachmentRequest) anyerror!void,
