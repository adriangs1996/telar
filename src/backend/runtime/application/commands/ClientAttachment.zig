const ClientAttachment = @This();
const LaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
context: *anyopaque,
replace: *const fn (*anyopaque, LaunchedPane) anyerror!void,
