const OpenPanePrepareLaunch = @import("OpenPanePrepareLaunch.zig");
const LaunchAuthority = @This();

context: *anyopaque,
prepare: *const fn (*anyopaque, OpenPanePrepareLaunch) anyerror![]const u8,
