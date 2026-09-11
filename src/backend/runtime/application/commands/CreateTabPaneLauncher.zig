/// Pane launch port whose success is the runtime pane commit point.
const PaneLauncher = @This();
const LaunchPane = @import("CreateTabLaunchPane.zig");
const LaunchedPane = @import("CreateTabLaunchedPane.zig");
context: *anyopaque,
launch: *const fn (*anyopaque, LaunchPane) anyerror!LaunchedPane,
