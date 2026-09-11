const LaunchAuthority = @This();
const PrepareLaunch = @import("OpenPanePrepareLaunch.zig");
context: *anyopaque,
prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
