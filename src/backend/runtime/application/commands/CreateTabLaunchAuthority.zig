const LaunchAuthority = @This();
const PrepareLaunch = @import("CreateTabPrepareLaunch.zig");
context: *anyopaque,
/// Validates client authority and returns a cwd borrowed until this call
/// to the handler completes.
prepare: *const fn (*anyopaque, PrepareLaunch) anyerror![]const u8,
