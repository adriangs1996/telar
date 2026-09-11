const PaneLauncher = @This();
const LaunchPane = @import("CreateWorkspaceLaunchPane.zig");
const LaunchedPane = @import("CreateWorkspaceLaunchedPane.zig");
context: *anyopaque,
launch: *const fn (*anyopaque, LaunchPane) anyerror!LaunchedPane,
