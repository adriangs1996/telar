const CreatePanePrepareLaunch = @import("CreatePanePrepareLaunch.zig");
const LaunchAuthority = @This();

context: *anyopaque,
prepare: *const fn (*anyopaque, CreatePanePrepareLaunch) anyerror![]const u8,
