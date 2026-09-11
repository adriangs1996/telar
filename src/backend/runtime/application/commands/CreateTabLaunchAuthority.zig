const CreateTabPrepareLaunch = @import("CreateTabPrepareLaunch.zig");
const LaunchAuthority = @This();

context: *anyopaque,
/// Validates client authority and returns a cwd borrowed until this call
/// to the handler completes.
prepare: *const fn (*anyopaque, CreateTabPrepareLaunch) anyerror![]const u8,
