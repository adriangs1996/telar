const CreateWorkspaceLaunchPane = @import("CreateWorkspaceLaunchPane.zig");
const CreateWorkspaceLaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
const PaneLauncher = @This();

context: *anyopaque,
launch: *const fn (*anyopaque, CreateWorkspaceLaunchPane) anyerror!CreateWorkspaceLaunchedPane,
