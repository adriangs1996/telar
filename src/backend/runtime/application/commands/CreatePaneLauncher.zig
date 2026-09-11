const CreatePaneLaunchPane = @import("CreatePaneLaunchPane.zig");
const PaneLaunchedType = @import("../../../pane/PaneLaunched.zig");
const PaneLauncher = @This();

context: *anyopaque,
launch: *const fn (*anyopaque, CreatePaneLaunchPane) anyerror!PaneLaunchedType,
