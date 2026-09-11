const PaneAttachment = @This();
const LaunchedPane = @import("CreateTabLaunchedPane.zig");
context: *anyopaque,
/// Projects the committed pane into the requesting client's attachments.
attach: *const fn (*anyopaque, LaunchedPane) anyerror!void,
