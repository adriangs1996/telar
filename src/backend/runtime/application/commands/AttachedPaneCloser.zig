const PaneIdType = @import("telar-core").PaneId;
const AttachedPaneCloser = @This();

context: *anyopaque,
request_close: *const fn (*anyopaque, PaneIdType) ?bool,
