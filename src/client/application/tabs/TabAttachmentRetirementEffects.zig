const PaneIdType = @import("telar-core").PaneId;
const Effects = @This();

context: *anyopaque,
attachment_pending: *const fn (*anyopaque, PaneIdType) bool,
detach_pane: *const fn (*anyopaque, PaneIdType) anyerror!void,
retire_attachment: *const fn (*anyopaque, PaneIdType) void,
hide_graphics: *const fn (*anyopaque, PaneIdType) anyerror!void,
