const PaneIdType = @import("telar-core").PaneId;
const PendingAttachments = @This();

context: *anyopaque,
pending: *const fn (*anyopaque, PaneIdType) bool,
