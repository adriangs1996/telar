const CreateTabLaunchedPane = @import("CreateTabLaunchedPane.zig");
const PaneAttachment = @This();

context: *anyopaque,
/// Projects the committed pane into the requesting client's attachments.
attach: *const fn (*anyopaque, CreateTabLaunchedPane) anyerror!void,
