const LaunchAuthority = @This();
const PrepareLaunch = @import("CreateWorkspacePrepareLaunch.zig");
context: *anyopaque,
prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
