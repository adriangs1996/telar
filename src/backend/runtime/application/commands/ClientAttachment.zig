const CreateWorkspaceLaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
const ClientAttachment = @This();

context: *anyopaque,
replace: *const fn (*anyopaque, CreateWorkspaceLaunchedPane) anyerror!void,
