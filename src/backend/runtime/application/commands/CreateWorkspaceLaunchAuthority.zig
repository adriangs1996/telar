const CreateWorkspacePrepareLaunch = @import("CreateWorkspacePrepareLaunch.zig");
const LaunchAuthority = @This();

context: *anyopaque,
prepare: *const fn (*anyopaque, CreateWorkspacePrepareLaunch) anyerror![]const u8,
