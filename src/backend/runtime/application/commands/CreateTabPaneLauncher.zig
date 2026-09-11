const CreateTabLaunchPane = @import("CreateTabLaunchPane.zig");
const CreateTabLaunchedPane = @import("CreateTabLaunchedPane.zig");
/// Pane launch port whose success is the runtime pane commit point.
const PaneLauncher = @This();

context: *anyopaque,
launch: *const fn (*anyopaque, CreateTabLaunchPane) anyerror!CreateTabLaunchedPane,
