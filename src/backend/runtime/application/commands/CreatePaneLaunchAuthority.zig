const LaunchAuthority = @This();
const PrepareLaunch = @import("CreatePanePrepareLaunch.zig");
context: *anyopaque,
prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
