const PaneLauncher = @This();
const LaunchPane = @import("CreatePaneLaunchPane.zig");
const pane_mod = @import("../../../pane/root.zig");
context: *anyopaque,
launch: *const fn (*anyopaque, LaunchPane) anyerror!pane_mod.PaneLaunched,
